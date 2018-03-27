#!/usr/bin/env luajit

local has_signal, signal = pcall(require, 'signal')
if not has_signal then io.stderr:write"No signal Support\n" end
local logger = require'logger'
local time = require'unix'.time
local poll = require'unix'.poll
local velodyne = require'velodyne_lidar'
local skt = require'skt'
local tinsert = require'table'.insert

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
assert(mpack)

local process = {
  velodyne.parse_data, velodyne.parse_position
}
local channels = {'velodyne', 'velodyne_nmea'}
local tsensors = {}
for i, name in ipairs(channels) do tsensors[i] = {} end
local skts = {
  assert(skt.open{
    port = velodyne.DATA_PORT,
    use_connect = false
  }),
  assert(skt.open{
    port = velodyne.POSITION_PORT,
    use_connect = false
  })
}
local fds = {}
for i, skt in ipairs(skts) do fds[i] = skt.fd end

local t_entry = time()
local log_dir = "./logs"
log = assert(logger.new('velodyne', log_dir))

-- Calculate the jitter in milliseconds
local function get_jitter(times)
  if #times<2 then return false end
  local jitter = 0
  local diffs, adiff = {}, 0
  for i=2,#times do
    local d = 1e3*(times[i] - times[i-1]) --milliseconds
    adiff = adiff + d
    table.insert(diffs, d)
  end
  local adiff = adiff / #diffs
  local jMin, jMax = math.min(unpack(diffs)), math.max(unpack(diffs))
  return adiff, jMin - adiff, jMax - adiff
end

local function exit()
  log:close()
  for i, skt in ipairs(skts) do skt:close() end
end

local running = true
local function shutdown()
  if running == false then
    running = nil
    io.stderr:write"!! Double shutdown\n"
    os.exit(exit())
  elseif running == nil then
    io.stderr:write"!! Final shutdown\n"
    os.exit(1)
  end
  running = false
end
if has_signal then
  signal.signal("SIGINT", shutdown);
  signal.signal("SIGTERM", shutdown);
end

local t_debug = time()
local n = 0
while running do
  local rc, ready = poll(fds)
  local t_poll = time()
  if rc and ready then
    for _, ind in ipairs(ready) do
      local pkt = skts[ind]:recv()
      local obj = process[ind](pkt)
      if obj then
        log:write(mpack(obj), channels[ind])
        tinsert(tsensors[ind], t_poll)
      end
    end
  end
  local dt_debug = t_poll - t_debug
  if dt_debug > 1 then
    local info = {}
    for i, times in ipairs(tsensors) do
      local avg, jitterA, jitterB = get_jitter(times)
      table.insert(info, string.format(
        "%s:\t%3d samples (%5.1f Hz)\tJitter: %+6.2f ms | %3d ms | %+6.2f ms",
        channels[i], #times, #times/dt_debug,
        jitterA or nan, avg or nan, jitterB or nan))
    end
    io.write('\n', table.concat(info, '\n'), '\n')
    for i in ipairs(tsensors) do tsensors[i] = {} end
    t_debug = t_poll
  end
end
exit()
