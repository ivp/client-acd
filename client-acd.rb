require 'rubygems'
require 'sinatra'
require 'sinatra-websocket'
require 'twilio-ruby'
require 'json/ext' # required for .to_json
require 'mongo'
require 'logger'

logger = Logger.new(STDOUT)
logger.level = Logger::DEBUG  #change to to get log level input from configuration

set :sockets, [] 
disable :protection  #necessary for ajax requests from a diffirent domain (like a SFDC iframe)

enable :sessions


#global vars
$sum = 0   #number of iterations of checking the queue 

############ CONFIG ###########################
# Find these values at twilio.com/user/account
account_sid = ENV['twilio_account_sid']
auth_token =  ENV['twilio_account_token']
app_id =  ENV['twilio_app_id']
caller_id = ENV['twilio_caller_id']  #number your agents will click2dialfrom
anycallerid = ENV['anycallerid'] || "none"   #If you set this in your ENV anycallerid=inline the callerid box will be displayed to users.  To use anycallerid (agents set their own caller id), your Twilio Account must be provisioned.  So default is false, agents wont' be able to use any callerid. 
workflow_id = ENV['twilio_workflow_id']
workspace_id = ENV['twilio_workspace_id']
task_queue_id = ENV['twilio_task_queue_id']
mongohqdbstring = ENV['MONGOLAB_URI']

########### DB Setup  ###################
configure do
  db = URI.parse(mongohqdbstring)
  db_name = db.path.gsub(/^\//, '')   
  @conn = Mongo::Connection.new(db.host, db.port).db(db_name)
  @conn.authenticate(db.user, db.password) unless (db.user.nil? || db.user.nil?)
  set :mongo_connection, @conn
end
# conversations will be stored in 'conversations' collection
mongoconvos = settings.mongo_connection['conversations']


##### end of db config #######


## used when outside of salesforce
default_client =  "default_client"

##### Twilio TaskRouter Client for workflow info
@trclient = Twilio::REST::TaskRouterClient.new(account_sid, auth_token, workspace_id)

logger.info("Starting up.. configuration complete")

#### thred

######### Main request Urls #########

### Returns HTML for softphone -- see html in /views/index.rb
get '/' do
  #for hmtl client
  client_name = params[:client]
  if client_name.nil?
        client_name = default_client
  end

  erb :index, :locals => {:anycallerid => anycallerid, :client_name => client_name}
end

## Returns a token for a Twilio client
get '/token' do
  client_name = params[:client]
  if client_name.nil?
        client_name = default_client
  end
  capability = Twilio::Util::Capability.new account_sid, auth_token
      # Create an application sid at twilio.com/user/account/apps and use it here
      capability.allow_client_outgoing app_id 
      capability.allow_client_incoming client_name
      token = capability.generate
  return token
end 

## Receives the client id loops through the defined workers for this workspace
## If a workers is defined with the client name it returns a token for the TaskRouter worker
get '/workertoken' do
  client_name = params[:client]
  if client_name
    @trclient = Twilio::REST::TaskRouterClient.new(account_sid, auth_token, workspace_id)
    workertoken = nil
    @trclient.workers.list.each do |worker|
      logger.info worker.friendly_name
      if worker.friendly_name == client_name
        worker_capability = Twilio::TaskRouter::Capability.new account_sid, auth_token, workspace_id, worker.sid
        worker_capability.allow_worker_fetch_attributes
        worker_capability.allow_worker_activity_updates
        workertoken = worker_capability.generate_token
      end
    end
  end
  return workertoken || ""
end 

# Conversation token generator
get '/conversationtoken' do
  endpoint_name = params[:client]
  if endpoint_name
    token = Twilio::Util::AccessToken.new account_sid, account_sid, auth_token
    token.add_endpoint_grant endpoint_name
    token.enable_nts
  end
  return token.to_jwt || ""
end

  
## WEBSOCKETS: Accepts a inbound websocket connection. Connection will be used to send messages to the browser, and detect disconnects
get '/websocket' do 

  request.websocket do |ws|
    #we use .onopen to identify new clients
    ws.onopen do
      logger.info("New Websocket Connection #{ws.object_id}") 

      #query is worker=workersid
      querystring = ws.request["query"]
      worker = querystring.split(/\=/)[1]
      logger.info("Worker #{worker} connected from Websockets")
      settings.sockets << ws   
    end

    #currently don't recieve websocket messages from client 
    ws.onmessage do |msg|
      logger.debug("Received websocket message:  #{msg}")
    end

    
    ##websocket close
    ws.onclose do
      querystring = ws.request["query"]
      worker = querystring.split(/\=/)[1]

      logger.info("Websocket closed for #{worker}")

      settings.sockets.delete(ws)

    end  ### End Websocket close


  end  #### End request.websocket 
end ### End get /websocket



# Handle incoming voice calls.
# You point your inbound Twilio phone number inside your Twilio account to this url, such as https://yourserver.com/voice
# Inbound calls will simply Enqueue the call to the workflow

post '/voice' do
  response = Twilio::TwiML::Response.new do |r|  
    r.Say("Please wait for the next availible agent ")
    r.Enqueue workflowSid: workflow_id do |e|
      e.TaskAttributes '{"task_type":"call"}'
    end
  end
  response.text
end

# Handle incoming SMS.
post '/sms' do
  active_conversation = nil
  # check for a conversation cookie
  if session[:task]
    # The cookie is present.  Look up to see if the conversation is still active
    task = session[:task]
    active_conversation = mongoconvos.find_one({ _id: task}) || false
  end
  # if the conversation is in the DB don't use TaskRouter.  Just push the message to the worker
  if active_conversation
    settings.sockets.each{|s|
      querystring = s.request["query"]
      worker = querystring.split(/\=/)[1]
      if (worker == active_conversation["worker"])
        msg = {:message => {:Body => params[:Body], :From => params[:From]}}.to_json
        s.send(msg)
      end
    }
  else
    # We will create a new task.  First form our Task from the incoming SMS
    task_attributes = {'task_type' => 'sms'}

    #merge the incoming sms into our attributes
    task_attributes = task_attributes.merge(params)

    # Start a client to TaskRouter so we can create a new task
    begin
      @trclient = Twilio::REST::TaskRouterClient.new(account_sid, auth_token, workspace_id)

      response = @trclient.tasks.create(attributes: task_attributes.to_json, WorkflowSid: workflow_id)

      # attach the task id to a cookie to track conversations
      session[:task] = response.sid
    rescue Twilio::REST::RequestError => e
      logger.info "Error creating task"
      logger.info e
    end
  end
end

#Ajax call to send an SMS
# - secure this in real life
post '/send_sms' do
  @client = Twilio::REST::Client.new(account_sid, auth_token)
  account = @client.account
  begin 
    message = account.messages.create(
      from: caller_id,
      to: params[:To],
      body: params[:Message]
    )
  rescue Twilio::REST::RequestError => e
    logger.info "Error sending SMS"
    logger.info e
  end
  return message.status
end


#######  This is called when agents click2dial ###############
# In Twilio, you set up a Twiml App, by going to Account -> Dev Tools - > Twiml Apps.  The app created here gives you the twilio_app_id requried for config.
# You then point the voice url for that app id to this url, such as "https://yourserver.com/dial" 
# This method will be called when a client clicks

post '/dial' do
    puts "Params for dial = #{params}"
    
    number = params[:PhoneNumber]


    response = Twilio::TwiML::Response.new do |r|
        # outboudn dialing (from client) must have a :callerId    
        r.Dial :callerId => caller_id do |d|
          d.Number number
        end
    end
    puts response.text
    response.text
end

#######  This is called when agents is selected by TaskRouter to send the task ###############
## We will use the dequeue method of handling the assignment 
### https://www.twilio.com/docs/taskrouter/handling-assignment-callbacks#dequeue-call
### from SMS messages we log the task associated with the worker to track conversations
post '/assignment' do
  attributes = JSON.parse params[:TaskAttributes]
  task = params[:TaskSid]
  worker = params[:WorkerSid]
  assignment_instruction = {}
  task_type = attributes["task_type"]
  case task_type
  when 'sms'
    assignment_instruction = {
      instruction: 'accept',
      from: attributes["From"]
    }
    # create a conversation in the db to track
    conversation = {_id: task, worker: worker}
    id = mongoconvos.update({_id: task},  conversation, {upsert: true})
  when 'call'
    assignment_instruction = {
      instruction: 'dequeue',
      from: attributes["from"]
    }
  end
  content_type :json
  assignment_instruction.to_json

end

post '/wrapup' do
  # Delete the db record as the conversation is now complete
  logger.info "we are going to delete #{params[:task]}"
  result = mongoconvos.remove({_id: params[:task]});
  logger.info result
end

post '/event' do
  # place holder for handling Workspace event callback
  # this would be place to store all that data goodness

end
######### End of Twilio methods

#ajax request from Web UI, acccepts a casllsid, do a REST call to redirect to /hold
post '/request_hold' do
    from = params[:from]  #agent name
    callsid = params[:callsid]  #call sid the agent has for their leg
    calltype = params[:calltype]


    @client = Twilio::REST::Client.new(account_sid, auth_token)
    if calltype == "Inbound"  #get parentcallsid
      callsid = @client.account.calls.get(callsid).parent_call_sid  #parent callsid is the customer leg of the call for inbound
    end


    puts "callsid = #{callsid} for calltype = #{calltype}"
    
    customer_call = @client.account.calls.get(callsid)
    customer_call.update(:url => "#{request.base_url}/hold",
                 :method => "POST")  
    puts customer_call.to
    return callsid
end

#Twiml response for hold, currently uses Monkey as hold music
post '/hold' do
    response = Twilio::TwiML::Response.new do |r|
      r.Play "http://com.twilio.sounds.music.s3.amazonaws.com/ClockworkWaltz.mp3", :loop=>0 
    end

    puts response.text
    response.text
end

## Ajax post request that retrieves from hold
post '/request_unhold' do
    from = params[:from]
    callsid = params[:callsid]  #this should be a valid call sid to  "unhold"

    @client = Twilio::REST::Client.new(account_sid, auth_token)

    call = @client.account.calls.get(callsid)
    call.update(:url => "#{request.base_url}/send_to_agent?target_agent=#{from}",
                 :method => "POST")  
    puts call.to
end

post '/send_to_agent' do
   target_agent = params[:target_agent]
   puts params

   #todo: update agent status from here - ie hold
   response = Twilio::TwiML::Response.new do |r|
      r.Dial do |d|
        d.Client target_agent
      end 
   end

   puts response.text
   response.text  

end

## Thread that polls to get current queue size, and updates websocket clients with new info
## We now use the TaskRouter rest client to query workers and agents
Thread.new do 
   while true do
     sleep(1)
     all_stats = @trclient.task_queues.get(task_queue_id)
     stats = all_stats.statistics.realtime
     qsize = stats["tasks_by_status"]["pending"]
     readycount = stats["total_available_workers"]

      settings.sockets.each{|s| 
        msg =  { :stats => {:queuesize => qsize, :readyagents => readycount}}.to_json
        #logger.debug("Sending webocket #{msg}");
        s.send(msg) 
      } 
     #logger.debug("run = #{$sum} #{Time.now} qsize = #{qsize} readyagents = #{readycount}")
  end
end

Thread.abort_on_exception = true
