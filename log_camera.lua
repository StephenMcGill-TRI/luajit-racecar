#!/usr/bin/env luajit
local devname = arg[1] or '/dev/video1'

local has_signal, signal = pcall(require, 'signal')
if not has_signal then io.stderr:write"No signal Support\n" end
local logger = require'logger'

local uvc = require'uvc'
local width = 1344
local height = 376
local camera = uvc.init(devname, width, height, 'yuyv', 1, 15)
assert(camera)

local jpeg = require'jpeg'
local c_yuyv = jpeg.compressor('yuyv')
c_yuyv:downsampling(0)

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

local unix = require'unix'

local t_entry = unix.time()
local log_dir = "./logs"
log = assert(logger.new('camera', log_dir))

local function exit()
  log:close()
  camera:close()
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

local t_debug = unix.time()
local n = 0
while running do
  local img, sz = camera:get_image(-1)
  local t = unix.time()
  if img then
    log:write(mpack{
      t = t,
      jpg = c_yuyv:compress(img, sz, width, height)
    })
    n = n + 1
  end
  local dt_debug = t - t_debug
  if dt_debug > 1 then
    io.stdout:write(string.format(
      "%3d images @ %f Hz\n", n, n/dt_debug))
    t_debug = t
    n = 0
  end
end
exit()
