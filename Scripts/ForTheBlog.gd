extends HTTPRequest

var token := "YourTokenHere" #make sure to actually replace this with your token!
var client : WebSocketClient
var heartbeat_interval : float
var last_sequence : float
var session_id : String
var heartbeat_ack_received := true
var invalid_session_is_resumable : bool

func _ready() -> void:
	randomize()
	client = WebSocketClient.new()
	client.connect_to_url("wss://gateway.discord.gg/?v=6&encoding=json")
	client.connect("connection_established", self, "_connection_established")
	client.connect("connection_closed", self, "_connection_closed")
	client.connect("server_close_request", self, "_server_close_request")
	client.connect("data_received", self, "_data_received")

func _process(delta : float) -> void:
	#check if the client is not disconnected, there's no point to poll it if it is
	if client.get_connection_status() != NetworkedMultiplayerPeer.CONNECTION_DISCONNECTED:
		client.poll()
	else:
		#If it is disconnected, try to resume
		client.connect_to_url("wss://gateway.discord.gg/?v=6&encoding=json")

func _connection_established(protocol : String) -> void:
	print("We are connected! Protocol: %s" % protocol)

func _connection_closed(was_clean_close : bool) -> void:
	print("We disconnected. Clean close: %s" % was_clean_close)

func _server_close_request(code : int, reason : String) -> void:
	print("The server requested a clean close. Code: %s, reason: %s" % [code, reason])

func _data_received() -> void:
	var packet := client.get_peer(1).get_packet()
	var data := packet.get_string_from_utf8()
	var json_parsed := JSON.parse(data)
	var dict : Dictionary = json_parsed.result
	var op = str(dict["op"]) #convert it to string for easier checking
	print(op)
	match op:
		"0": #Opcode 0 Dispatch (Events)
			handle_events(dict)
		"9": #Opcode 9 Invalid Session
			invalid_session_is_resumable = dict["d"]
			$InvalidSessionTimer.one_shot = true
			$InvalidSessionTimer.wait_time = rand_range(1, 5)
			$InvalidSessionTimer.start()
		"10": #Opcode 10 Hello
			#Set our timer
			heartbeat_interval = dict["d"]["heartbeat_interval"] / 1000
			$HeartbeatTimer.wait_time = heartbeat_interval
			$HeartbeatTimer.start()
			
			var d := {}
			if !session_id:
				#Send Opcode 2 Identify to the Gateway
				d = {
					"op" : 2,
					"d" : { "token" : token, "properties" : {} }
				}
			else:
				#Send Opcode 6 Resume to the Gateway
				d = {
					"op" : 6,
					"d" : { "token" : token, "session_id" : session_id, "seq" : last_sequence}
				}
			send_dictionary_as_packet(d)
		"11": #Opcode 11 Heartbeat ACK
			heartbeat_ack_received = true
			print("We've received a Heartbeat ACK from the gateway.")


func _on_HeartbeatTimer_timeout() -> void: #Send Opcode 1 Heartbeat payloads every heartbeat_interval
	if !heartbeat_ack_received:
		#We haven't received a Heartbeat ACK back, so we'll disconnect
		client.disconnect_from_host(1002)
		return
	var d := {"op" : 1, "d" : last_sequence}
	send_dictionary_as_packet(d)
	heartbeat_ack_received = false
	print("We've send a Heartbeat to the gateway.")

func send_dictionary_as_packet(d : Dictionary) -> void:
	var query = to_json(d)
	client.get_peer(1).put_packet(query.to_utf8())

func handle_events(dict : Dictionary) -> void:
	last_sequence = dict["s"]
	var event_name : String = dict["t"]
	print(event_name)
	match event_name:
		"READY":
			session_id = dict["d"]["session_id"]
		"GUILD_MEMBER_ADD":
			var guild_id = dict["d"]["guild_id"]
			var headers := ["Authorization: Bot %s" % token]
			
			#Get all channels of the guild
			request("https://discordapp.com/api/guilds/%s/channels" % guild_id, headers)
			var data_received = yield(self, "request_completed") #await
			var channels = JSON.parse(data_received[3].get_string_from_utf8()).result
			var channel_id
			for channel in channels:
				#Find the first text channel and get its ID
				if str(channel["type"]) == "0":
					channel_id = channel["id"]
					break
			if channel_id: #if we found at least one text channel
				var username = dict["d"]["user"]["username"]
				var message_to_send := {"content" : "Welcome %s!" % username}
				var query := JSON.print(message_to_send)
				headers.append("Content-Type: application/json")
				request("https://discordapp.com/api/v6/channels/%s/messages" % channel_id, headers, true, HTTPClient.METHOD_POST, query)
		"MESSAGE_CREATE":
			var channel_id = dict["d"]["channel_id"]
			var message_content = dict["d"]["content"]
			
			var headers := ["Authorization: Bot %s" % token, "Content-Type: application/json"]
			var query : String
			
			if message_content.to_upper() == "ORAMA":
				var message_to_send := {"content" : "Interactive"}
				query = JSON.print(message_to_send)
			elif message_content.to_upper() == "WEBSITE":
				var message_to_send := {"content" : "http://oramagamestudios.com/"}
				query = JSON.print(message_to_send)
			elif message_content.to_upper() == "BLOG":
				var message_to_send := {"content" : "https://functionoverload590613498.wordpress.com"}
				query = JSON.print(message_to_send)
			elif message_content.to_upper() == "GITHUB":
				var message_to_send := {"content" : "https://github.com/OverloadedOrama"}
				query = JSON.print(message_to_send)
			if query:
				request("https://discordapp.com/api/v6/channels/%s/messages" % channel_id, headers, true, HTTPClient.METHOD_POST, query)

func _on_InvalidSessionTimer_timeout() -> void:
	var d := {}
	if invalid_session_is_resumable && session_id:
		#Send Opcode 6 Resume to the Gateway
		d = {
			"op" : 6,
			"d" : { "token" : token, "session_id" : session_id, "seq" : last_sequence}
		}
	else:
		#Send Opcode 2 Identify to the Gateway
		d = {
			"op" : 2,
			"d" : { "token" : token, "properties" : {} }
		}
	send_dictionary_as_packet(d)
