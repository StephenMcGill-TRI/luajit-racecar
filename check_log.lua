#!/usr/bin/env luajit
local logger = require'logger'
local fname = assert(arg[1], "No log specified")
local datestamp = assert(
  fname:match(logger.iso8601_match), "Bad log datestamp")

local USE_BROADCAST = false
local DEBUG_CHANNEL = arg[2] or false

local has_unix, unix = pcall(require, 'unix')

local skt_mcl
if USE_BROADCAST then
  local MCL_ADDRESS, MCL_PORT = "239.255.65.56", 6556
  local skt = require'skt'
  skt_mcl, err = assert(skt.open{
    address = MCL_ADDRESS,
    port = MCL_PORT
  })
end

local channels = {}
local rates = {}
local t_last = {}

local mpack, munpack
-- Two different MessagePack implementations...
local has_mp, mp
local has_mp_lj, mp_lj = pcall(require, 'luajit-msgpack-pure')
if has_mp_lj then
  has_mp = true
  mpack = mp_lj.pack
  munpack = function(str)
    local offset, obj = mp_lj.unpack(str)
    return obj
  end
else
  -- Fallback support
  io.stderr:write"No lj-msgpack support\n"
  has_mp, mp = pcall(require, 'MessagePack')
  mpack = mp.pack
  munpack = mp.unpack
end
if not has_mp then io.stderr:write"No msgpack support\n" end

local i = 0
local dt_save = -math.huge
local d_yaw = 0
local DEG_TO_RAD = math.pi/180
local t_prev_entry
local t_us0, t_us1
for data_str, channel_name, t_us, count
  in logger.play_it(fname) do
  t_us0 = t_us0 or t_us
  t_us1 = t_us
  channels[channel_name] = (channels[channel_name] or 0) + 1
  -- Timing
  local t_prev = t_last[channel_name] or t_us
  local dt = tonumber(t_us - t_prev)
  t_last[channel_name] = t_us
  rates[channel_name] = (rates[channel_name] or dt) * 0.9 + dt * 0.1

  -- Debugging output
  if channel_name==DEBUG_CHANNEL or DEBUG_CHANNEL==true then
    local obj = munpack(data_str)
    print(string.format("\n[%s] @ %d",
      channel_name, tonumber(t_us), tonumber(count)))
    for k, v in pairs(obj) do print(k, v) end
    if USE_BROADCAST then
      local payload = mpack(obj)
      print("Broadcasting...", #payload)

      unix.usleep(t_us - (t_prev_entry or t_us))
      skt_mcl:send(payload)
    end
  end
  t_prev_entry = t_us
end

print(string.format(
  "Log spanned %.2f seconds",
  tonumber(t_us1-t_us0) / 1e6
))
print("Channel\tCount\tms\tHz")
for ch, count in pairs(channels) do
  print(string.format("%s\t%d\t%.3f\t%.1f", ch, count, rates[ch] / 1e3, 1e6 / rates[ch]))
end
