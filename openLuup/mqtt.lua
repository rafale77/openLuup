local ABOUT = {
  NAME          = "openLuup.mqtt",
  VERSION       = "2021.03.01b",
  DESCRIPTION   = "MQTT v3.1.1 QoS 0 server",
  AUTHOR        = "@akbooer",
  COPYRIGHT     = "(c) 2020-2021 AKBooer",
  DOCUMENTATION = "https://github.com/akbooer/openLuup/tree/master/Documentation",
  DEBUG         = false,
  LICENSE       = [[
  Copyright 2020-2021 AK Booer

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
]]
}

--
-- MQTT Message Queuing Telemetry Transport for openLuup
--

-- 2021.01.31   original version
-- 2021.02.17   add login credentials


-- see OASIS standard: http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.pdf
-- Each conformance statement has been assigned a reference in the format [MQTT-x.x.x-y]

local logs      = require "openLuup.logs"
local tables    = require "openLuup.servertables"     -- for myIP
local ioutil    = require "openLuup.io"               -- for core server functions
local scheduler = require "openLuup.scheduler"

--  local _log() and _debug()
local _log, _debug = logs.register (ABOUT)

local iprequests = {}


-------------------------------------------
--
-- MQTT servlet
--

local MQTT_packet = {}

--[[
  Structure of an MQTT Control Packet:
    Fixed header, present in all MQTT Control Packets 
    Variable header, present in some MQTT Control Packets 
    Payload, present in some MQTT Control Packets
--]]

do -- MQTT Packet methods

  -- control packet names: an ordered list, 1 - 15.
  local pname = {
      "CONNECT", "CONNACK", "PUBLISH", 
      "PUBACK", "PUBREC", "PUBREL", "PUBCOMP", 
      "SUBSCRIBE", "SUBACK", "UNSUBSCRIBE", "UNSUBACK", 
      "PINGREQ", "PINGRESP",
      "DISCONNECT"
    }

  -- packet type
  local ptype = {}
  for i, name in ipairs (pname) do
    ptype[name] = i
  end

  -- split flag char into individual boolean bits (default is 8 bits)
  local function parse_flags (x, n)
    n = n or 8
    if type(x) == "string" then x = x:byte() end    -- convert to number
    local bits = {}
    for i = n,1,-1 do
      local b = x % 2
      x = (x - b) / 2
      bits[i] = b 
    end
    return bits
  end

  local function parse_packet_type (header)
    -- byte 1: MQTT Control Packet type / Flags specific to each MQTT Control Packet type
    local a = string.byte (header)
    local nibble = 0x10
    local packet_type = math.floor (a / nibble)
    local flags = parse_flags (a % nibble, 4)
    return packet_type, flags
  end
  
  local function bytes2word (bytes)
    local msb, lsb = bytes: byte (1, 2)
    return msb * 0x100 + lsb
  end

  local function read_flag_byte (msg)
      return parse_flags (msg: read_bytes(1))      -- byte 8
  end
  
  local function read_word (msg)
    return bytes2word (msg: read_bytes (2))
  end

  -- read string from message
  local function read_utf8 (msg)
    local n = msg: read_word ()      -- length of this string
    return msg: read_bytes (n)
  end

  -- read next n bytes from message
  local function read_bytes (msg, n)
    local i = msg.ptr + 1
    local j = msg.ptr + n
    local b = msg.body
    if #b >= j then
      msg.ptr = j
      return b: sub (i,j)
    end
  end

  -- return 16-bit word as a two-byte string
  local function word2bytes (word)
    word = word % 0x10000
    local msb = math.floor (word / 0x100)
    local lsb = word % 0x100
    return string.char (msb, lsb)
  end

  -- prepend a string (assumed UTF-8) with its length
  local function encode_utf8 (txt)
    local length = word2bytes (#txt)
    return length .. txt
  end
    
  -- encode for transmission
  local function encode (packet_type, control_flags, variable_header, payload)
    variable_header = variable_header or ''
    payload = payload or ''
    packet_type = ptype[packet_type] or packet_type   -- convert to number if string type
    local length = #variable_header + #payload
    
    local nibble = 0x10
    local byte1 = (packet_type % nibble) * nibble + (control_flags % nibble)
    local bytes = {string.char (byte1)}       -- first part of fixed header
    repeat
      local encodedByte = length % 128
      length = math.floor (length / 128)
      -- if there are more data to encode, set the top bit of this byte 
      bytes[#bytes+1] = string.char (encodedByte + (length > 0 and 128 or 0))
    until length == 0
    local fixed_header = table.concat (bytes)
    
    return table.concat {fixed_header, variable_header, payload}
  end


  -- receive returns messsage object, or error message
  function MQTT_packet.receive (client)
    local err
    local fixed_header_byte1
    fixed_header_byte1, err = client: receive (1)
      if not fixed_header_byte1 then return nil, err end
    local packet_type, control_flags = parse_packet_type (fixed_header_byte1)

    local length = 0
    for i = 0, 2 do                   -- maximum of 3 bytes encode remaining length, LSB first
      local b, err = client: receive (1)
      if not b then return nil, err end
      b = b: byte()
      local n = b % 128               -- seven significant bits
      length = length + n * 128 ^ i
      if b < 128 then break end
    end
    
    local body = ''
    if length > 0 then
      body, err = (length > 0) and client: receive (length)
      if not body then return nil, err end
    end
    
    local pname = pname[packet_type] or "RESERVED"
    
    return {
        -- variables
        packet_type     = packet_type,
        control_flags   = control_flags,
        body            = body,           -- may include variable header and payload
        ptr             = 0,              -- pointer to parse position in body
        packet_name     = pname,          -- string name of packet type

        -- methods
        read_bytes      = read_bytes,
        read_flag_byte  = read_flag_byte, -- converting octet to 8 separate flag bits
        read_word       = read_word,
        read_string     = read_utf8,
      }
  end

  -------------------------------------------
  --
  -- Construct MQTT packets
  --
  -- only implement functionality required by server
  --

  function MQTT_packet.CONNECT () end          -- client only

  function MQTT_packet.CONNACK (ConnectReturnCode)
    local packet_type, control_flags = "CONNACK", 0 
    
    local SessionPresent = 0                      -- QoS 0 means that there will be no Session State
    ConnectReturnCode = ConnectReturnCode or 0
    local variable_header = string.char (SessionPresent, ConnectReturnCode)
    
    local connack = encode (packet_type, control_flags, variable_header)    -- connack has no payload
    return connack
  end

  function MQTT_packet.PUBLISH (TopicName, ApplicationMessage) 
    -- publish to MQTT client socket (with QoS = 0)
    
    -- FIXED HEADER
    local packet_type = "PUBLISH"
    local control_flags = 0               -- QoS = 0
    
    -- VARIABLE HEADER
    local variable_header = encode_utf8 (TopicName)   -- No packetId, since QoS = 0
    
    -- PAYLOAD
    local payload = ApplicationMessage
    
    local publish = encode (packet_type, control_flags, variable_header, payload)
    return publish
  end

  function MQTT_packet.PUBACK ()  end          -- not implemented (only required for QoS > 0)
  function MQTT_packet.PUBREC ()  end          -- ditto
  function MQTT_packet.PUBREL ()  end          -- ditto
  function MQTT_packet.PUBCOMP () end          -- ditto

  function MQTT_packet.SUBSCRIBE () end        -- client only

  function MQTT_packet.SUBACK (QoS_list, PacketId) 
    -- When the Server receives a SUBSCRIBE Packet from a Client, the Server MUST respond with a SUBACK Packet [MQTT-3.8.4-1]
    -- The SUBACK Packet MUST have the same Packet Identifier as the SUBSCRIBE Packet that it is acknowledging [MQTT-3.8.4-2]
    local control_flags = 0
    local variable_header = word2bytes (PacketId)
    local payload = QoS_list
    local suback = encode ("SUBACK", control_flags, variable_header, payload)
    return suback
  end

  function MQTT_packet.UNSUBSCRIBE () end      -- client only

  function MQTT_packet.UNSUBACK (PacketId)
    local control_flags = 0
    local variable_header = word2bytes (PacketId)
    local unsuback = encode ("UNSUBACK", control_flags, variable_header)    -- no payload
    return unsuback
  end

  function MQTT_packet.PINGREQ () end          -- client only

  function MQTT_packet.PINGRESP () 
    -- The Server MUST send a PINGRESP Packet in response to a PINGREQ packet [MQTT-3.12.4-1]
    --  local control_flags = 0
    --  local pingresp = encode ("PINGRESP", control_flags)  -- no variable_header or payload 
    local pingresp = string.char (13 * 0x10, 0)
    return pingresp
  end

  function MQTT_packet.DISCONNECT () end      -- client only


end


-------------------------------------------
--
-- Parse and process MQTT packets
--

local parse = {}


function parse.DISCONNECT()
  -- After sending a DISCONNECT Packet the Client MUST close the Network Connection [MQTT-3.14.4-1]
  return nil, "Disconnect received from client"
end

function parse.CONNECT(message, credentials)
  --  the first Packet sent from the Client to the Server MUST be a CONNECT Packet [MQTT-3.1.0-1]    
  
  -- VARIABLE HEADER
  
  -- If the protocol name is incorrect the Server MAY disconnect the Client
  local ProtocolName = message: read_string()                     -- bytes 1-6
  if ProtocolName ~= "MQTT" then 
    return nil, "Unknown protocol name: '" .. ProtocolName .. "'"
  end
  
  -- protocol level should be 4 for MQTT 3.1.1
  local protocol_level = message: read_bytes (1) : byte()         -- byte 7
  if protocol_level ~= 4 then 
    return nil, "Protocol level is not 3.1.1"
  end
  
  local connect_flags = message: read_flag_byte()                 -- byte 8
  
  local KeepAlive, Username, Password, 
          WillRetain, WillQoSmsb, WillQoSlsb, WillFlag,
          Clean, Reserved, WillQoS
  
  KeepAlive = message: read_word()                                -- bytes 9-10
  
  Username, Password, 
          WillRetain, WillQoSmsb, WillQoSlsb, WillFlag, 
          Clean, Reserved
            = unpack (connect_flags)
  WillQoS = 2 * WillQoSmsb + WillQoSlsb
  
  -- If invalid flags are received, the receiver MUST close the Network Connection [MQTT-2.2.2-2]
  -- The Server MUST validate that the reserved flag in the CONNECT Control Packet is set to zero 
  -- and disconnect the Client if it is not zero.[MQTT-3.1.2-3]
  if Reserved ~= 0 then   
    return nil, "Reserved flag is not zero" 
  end
  
  -- PAYLOAD
  
  local ConnectReturnCode = 0                       -- default to success
  local ClientId, WillTopic, WillMessage
  
  ClientId    = message: read_string()              -- always present
  
  WillTopic   = WillFlag == 1 and message: read_string() or ''
  WillMessage = WillFlag == 1 and message: read_string() or ''
  Username    = Username == 1 and message: read_string() or ''
  Password    = Password == 1 and message: read_string() or ''
  
-- If the User Name Flag is set to 0, a user name MUST NOT be present in the payload [MQTT-3.1.2-18]
-- If the User Name Flag is set to 1, a user name MUST be present in the payload [MQTT-3.1.2-19]
-- If the Password Flag is set to 0, a password MUST NOT be present in the payload [MQTT-3.1.2-20]
-- If the Password Flag is set to 1, a password MUST be present in the payload [MQTT-3.1.2-21]

-- These fields, if present, MUST appear in the order 
--   Client Identifier, Will Topic, Will Message, User Name, Password [MQTT-3.1.3-1]

-- The Client Identifier (ClientId) MUST be present and MUST be the first field in the CONNECT packet payload [MQTT-3.1.3-3]
  _debug ("ClientId: " .. ClientId)
  _debug ("WillTopic: " .. WillTopic)
  _debug ("WillMessage: " .. WillMessage)
  _debug ("UserName: " .. Username)
  _debug ("Password: " .. Password)
  
  -- ACKNOWLEDGEMENT
  -- If CONNECT validation is successful the Server MUST acknowledge the CONNECT Packet 
  -- with a CONNACK Packet containing a zero return code [MQTT-3.1.4-4]     
  -- If the Server does not have stored Session state, it MUST set Session Present to 0 in the CONNACK packet [MQTT-3.2.2-3]
  --[[
      MQTT Connection Return Codes
      [0] = "Connection Accepted",
      [1] = "Connection Refused, unacceptable protocol version",
      [2] = "Connection Refused, identifier rejected",
      [3] = "Connection Refused, Server unavailable",
      [4] = "Connection Refused, bad user name or password",
      [5] = "Connection Refused, not authorized",
  --]]

  if Username ~= credentials.Username 
  or Password ~= credentials.Password then
    ConnectReturnCode = 4                   -- "Connection Refused, bad user name or password"
  end

  local connack = MQTT_packet.CONNACK (ConnectReturnCode)
  
  -- If a server sends a CONNACK packet containing a non-zero return code it MUST then close the Network Connection [MQTT-3.2.2-5]
  local err
  if ConnectReturnCode ~= 0 then
    err = "Closing client connect, return code: " .. ConnectReturnCode
  end
  return connack, err
end

function parse.CONNACK()
  -- don't expect to receive a connack, since we don't connect to a server
end

function parse.PUBLISH(message)
  
  local flags = message.control_flags
  local DUP, QoSmsb, QoSlsb, RETAIN
  DUP, QoSmsb, QoSlsb, RETAIN = unpack (flags)
  local QoS = 2 * QoSmsb + QoSlsb
  
  -- VARIABLE HEADER
  
  -- The Topic Name MUST be present as the first field in the PUBLISH Packet Variable header [MQTT-3.3.2-1]
  local TopicName = message: read_string ()
  
  -- PUBLISH (in cases where QoS > 0) Control Packets MUST contain a non-zero 16-bit Packet Identifier [MQTT-2.3.1-1]
  -- A PUBLISH Packet MUST NOT contain a Packet Identifier if its QoS value is set to 0 [MQTT-2.3.1-5]
  local PacketId        -- packet identifier
  if QoS > 0 then
    PacketId = message: read_word()
  end
  
  -- PAYLOAD
  
  local ApplicationMessage = message.body: sub(message.ptr + 1, -1)      -- remaining part of body
  
  -- ACKNOWLEDGEMENT
  -- The receiver of a PUBLISH Packet MUST respond according to Table 3.4 - Expected Publish Packet
  --   response as determined by the QoS in the PUBLISH packet [MQTT-3.3.4-1]
  --[[
        Table 3.4 - Expected Publish Packet response
        QoS Level Expected Response
        QoS 0 None
        QoS 1 PUBACK Packet 
        QoS 2 PUBREC Packet
--]]
  local ack    -- None, because we only handle QoS 0
  return ack, nil, TopicName, ApplicationMessage
end

function parse.PINGREQ ()
  -- The Server MUST send a PINGRESP Packet in response to a PINGREQ packet [MQTT-3.12.4-1]
  local pingresp = MQTT_packet.PINGRESP ()
  return pingresp
end

function parse.PINGRESP ()
  -- unlikely, since we don't send PINGREQ
end

function parse.SUBSCRIBE (message)   
  -- Bits 3,2,1 and 0 of the fixed header of the SUBSCRIBE Control Packet are reserved 
  -- and MUST be set to 0,0,1 and 0 respectively [MQTT-3.8.1-1]
  local Reserved  = table.concat (message.control_flags) 
  if Reserved ~= "0010" then
    return nil, "Unexpected reserved flag bits: " .. Reserved
  end
  
  -- VARIABLE HEADER
  
  -- SUBSCRIBE Control Packets MUST contain a non-zero 16-bit Packet Identifier [MQTT-2.3.1-1]
  local PacketId = message: read_word()
  local pid = "Packet Id: 0x%04x"
  _debug (pid: format (PacketId))
  
  -- PAYLOAD
  
  local topics = {}
  repeat
    local topic = message: read_string()
    topics[#topics+1] =topic
    _debug ("Topic: " .. topic)
    local RequestedQoS
    RequestedQoS = message: read_bytes(1) :byte()
--      _log ("Requested QoS: " .. RequestedQoS)
  until message.ptr >= #message.body
  
  -- The payload of a SUBSCRIBE packet MUST contain at least one Topic Filter / QoS pair [MQTT-3.8.3-3]
  if #topics == 0 then
    return nil, "No topics found in SUBSCRIBE payload"
  end
  
  -- ACKNOWLEDGEMENT
  -- When the Server receives a SUBSCRIBE Packet from a Client, the Server MUST respond with a SUBACK Packet [MQTT-3.8.4-1]
  -- The SUBACK Packet MUST have the same Packet Identifier as the SUBSCRIBE Packet that it is acknowledging [MQTT-3.8.4-2]
  -- The SUBACK Packet sent by the Server to the Client MUST contain a return code for each Topic Filter/QoS pair. 
  --   This return code MUST either show the maximum QoS that was granted for that Subscription 
  --   or indicate that the subscription failed [MQTT-3.8.4-5]
  -- The Server might grant a lower maximum QoS than the subscriber requested. 
  --   The QoS of Payload Messages sent in response to a Subscription MUST be the minimum of the QoS 
  --   of the originally published message and the maximum QoS granted by the Server [MQTT-3.8.4-6]
  
  local nt = #topics
  local QoS_list = string.char(0): rep (nt)   -- regardless of RequestedQoS, we're using QoS = 0 for everything
  local suback = MQTT_packet.SUBACK (QoS_list, PacketId)
  return suback, nil, topics
end

function parse.UNSUBSCRIBE (message)
  -- Bits 3,2,1 and 0 of the fixed header of the UNSUBSCRIBE Control Packet are reserved 
  -- and MUST be set to 0,0,1 and 0 respectively [MQTT-3.10.1-1]
  local Reserved  = table.concat (message.control_flags) 
  if Reserved ~= "0010" then
    return nil, "Unexpected reserved flag bits: " .. Reserved
  end
  
  -- VARIABLE HEADER
  
  local PacketId = message: read_word()
  local pid = "Packet Id: 0x%04x"
  _debug (pid: format (PacketId))
  
  -- PAYLOAD
  
  local topics = {}
  repeat
    local topic = message: read_string()
    topics[#topics+1] =topic
    _debug ("Topic: " .. topic)
  until message.ptr >= #message.body
 
  --  The Payload of an UNSUBSCRIBE packet MUST contain at least one Topic Filter. 
  --  An UNSUBSCRIBE packet with no payload is a protocol violation [MQTT-3.10.3-2]
  if #topics == 0 then
    return nil, "No topics found in SUBSCRIBE payload"
  end
  
  -- ACKNOWLEDGEMENT
  -- The Server MUST respond to an UNSUBSUBCRIBE request by sending an UNSUBACK packet. 
  -- The UNSUBACK Packet MUST have the same Packet Identifier as the UNSUBSCRIBE Packet [MQTT-3.10.4-4]
  local unsuback = MQTT_packet.UNSUBACK (PacketId)
  return unsuback, nil, topics
end


-------------------------------------------
--
-- Subscriptions
--

local subscriptions = {} do
  
  -- meta methods
  -- these have to be in the metatable because we don't want their names to appear in the subscriptions list
  
  local method = {}
  
  function method: unsubscribe_client_from_topic (client, topic)
    local name = tostring(client)
    local message = "Unsubscribed from %s %s"
    local subs = self[topic] 
    if not subs then return end
    for i = #subs, 1, -1 do
      if subs[i] == client then 
        table.remove (subs, i)
        _log (message: format (topic, name))
      end
    end
  end

  function method: close_and_unsubscribe_from_all (client, log_message)
    client: close()
    if log_message then _log (table.concat {log_message, ' ', tostring(client)}) end
    for topic in pairs (self) do
      self: unsubscribe_client_from_topic (client, topic)
    end
  end

  -- register an internal (openLuup), or external, subscriber to a topic
  -- wildcards not (yet) implemented
  function method: subscribe(subscription)
    local topic = subscription.topic
    local subs = self[topic] or {}
    self[topic] = subs
    subs[#subs+1] = subscription
    return 1
  end

  -- register an openLuup-side subscriber to a single topic
  function method: register_handler (callback, topic)
    self: subscribe {
      callback = callback, 
      devNo = scheduler.current_device (),
      topic = topic,
      count = 0,
    }
    return 1
  end

  -- subscribe as external (IP) clients
  function method: subscribe_to_topics (client, topics)
    for _, topic in ipairs (topics) do
      self: subscribe {
        client = client, 
        topic = topic,
        count = 0,
      }
    end
  end

  function method: send_to_client (client, message)
    local ok, err = client: send (message)
    if not ok then
      self: close_and_unsubscribe_from_all (client, err)
    end
    return ok, err
  end

  -- deliver message to all subscribers
  function method: publish (TopicName, ApplicationMessage)
    -- publish message to all subscribers
    local function publish_to_all (subscribers, TopicName, ApplicationMessage)
      local message
      for _, subscriber in ipairs (subscribers) do
        local s = subscriber
        s.count = (s.count or 0) + 1
        local ok, err
        if s.callback then
          ok, err = scheduler.context_switch (s.devNo, s.callback, TopicName, ApplicationMessage)
        elseif s.client then
          message = message or MQTT_packet.PUBLISH (TopicName, ApplicationMessage)
          ok, err = self: send_to_client (s.client, message) -- publish to external subscribers
        end

        if not ok then
          _log (table.concat {"ERROR publishing application message for mqtt:", TopicName, " : ", err})
        else
    --      _log ("Successfully published: " .. TopicName)
        end
      end
    end
    if #TopicName == 0 then return end
    
    local subscribers = self[TopicName]
    if subscribers then
      publish_to_all (subscribers, TopicName, ApplicationMessage)     -- topic subscribers
    end
    
    
    subscribers = self['#']          -- TODO: better wildcards
    if subscribers then
      publish_to_all (subscribers, TopicName, ApplicationMessage)
    end
  end
  
  -- note that each subscription has a separate metatable, but shares the __index table of methods
  -- TODO: wildcard subscriptions are held in the metatable.wildcards variable
  
  function method.new ()
    return setmetatable ({}, {__index = method, wildcards = {}})    -- list of subscribers, indexed by topic
  end

  setmetatable (subscriptions, {__index = method, wildcards = {}})
  
end

-------------------------------------------
--
-- Generic MQTT incoming message handler
--

local function reserved(message)
  return nil, "UNIMPLEMENTED packet type: " .. message.packet_type
end

local function incoming (client, credentials, subscriptions)
  
  local ack
  local pname = "RECEIVE ERROR"
  local message, errmsg = MQTT_packet.receive (client)
  
  if message then
    pname = message.packet_name
    _debug (table.concat {pname, ' ', tostring(client)})
    
    -- analyze the message
    local topic, app_message
    local process = parse[pname] or reserved
    
    -- ack is an acknowledgement package to send back to the client
    -- errmsg signals an error requring the client connection to be closed
    -- topic may be a list for (un)subscribe, or a single topic to publish
    -- app_message is the appplication message for publication
    ack, errmsg, topic, app_message = process (message, credentials)    -- credentials used for CONNECT authorization
    
    -- send an ack if required
    if ack then
      subscriptions: send_to_client (client, ack)
    end
    
    if topic then
      
      if app_message then
        
        -- publish topic to subscribers
        subscriptions: publish (topic, app_message)
      
      elseif pname == "SUBSCRIBE" then
        
        -- add any subscriber to list of topics
        subscriptions: subscribe_to_topics (client, topic)
        
      elseif pname == "UNSUBSCRIBE" then
        
        -- unsubscribe external (IP) clients
        for _, t in ipairs (topic) do
          subscriptions: unsubscribe_client_from_topic (client, t)
        end

      end
    end
  end
  
  -- disconnect client on error
  if errmsg then
    subscriptions: close_and_unsubscribe_from_all (client, table.concat {pname, ": ", errmsg or '?'})
  end
end

-------------------------------------------
--
-- MQTT server
--

-- create additional MQTT servers (on different ports - or no port at all!)
local function new (config)
  config = config or {}
  
  local credentials = {                                 -- pull credentials from the config table (not used by ioutil.server)
      Username = config.Username or '',
      Password = config.Password or '',
    }
  
  local subscribers = subscriptions.new ()              -- a whole new list of subscribers
  
  local function servlet(client)
    return function () incoming (client, credentials, subscribers) end
  end
  
  local port = config.Port
  if port then                                            -- possible to create a purely internal MQTT 'server'
    ioutil.server.new {
        port      = port,                                 -- incoming port
        name      = "MQTT:" .. port,                      -- server name
        backlog   = config.Backlog or 100,                -- queue length
        idletime  = config.CloseIdleSocketAfter or 120,   -- connect timeout
        servlet   = servlet,                              -- our own servlet
        connects  = iprequests,                           -- use our own table for info
      }
  end
  
  return {
      -- note that these instance methods should be called with the colon syntax
      subscribe = function (_, ...) subscribers: register_handler (...) end,     -- callback for subscribed messages
      publish = function (_, ...) subscribers: publish (...) end,                -- publish from within openLuup
    }
end


-- start main openLuup MQTT server
local function start (config)

  ABOUT.DEBUG = config.DEBUG 
  
  local credentials = {
      Username = config.Username or '',
      Password = config.Password or '',
    }

  local function MQTTservlet (client)
    return function () incoming (client, credentials, subscriptions) end
  end 
  
  -- returned server object has stop method, but we'll not be using it
  local port = config.Port or 1883
  return ioutil.server.new {
      port      = port,                                 -- incoming port
      name      = "MQTT:" .. port,                      -- server name
      backlog   = config.Backlog or 100,                -- queue length
      idletime  = config.CloseIdleSocketAfter or 120,   -- connect timeout
      servlet   = MQTTservlet,                          -- our own servlet
      connects  = iprequests,                           -- use our own table for info
    }
end


--- return module variables and methods
return {
    ABOUT = ABOUT,
    
    TEST = setmetatable ({}, {          -- for testing only
      MQTT_packet = MQTT_packet,
      packet = MQTT_packet,
      parse = parse,
      subscriptions = subscriptions,
    }),
    
    -- constants
    myIP = tables.myIP,
    
    -- methods
    start = start,
    register_handler = function (...) subscriptions: register_handler (...) end,  -- callback for subscribed messages
    publish = function (...) subscriptions: publish (...) end,                    -- publish from within openLuup
    
    new = new,       -- create another new MQTT server
    
    -- variables
    iprequests  = iprequests,
    subscribers = subscriptions,

}