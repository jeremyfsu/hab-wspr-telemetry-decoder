#!/usr/local/bin/ruby
require 'socket'
require 'click_house'
require 'dx/grid'
require 'date'
require 'yaml'
require 'redis'

LOG = Logger.new(STDOUT)

Config = YAML.load_file('config.yml')
LOG.level = Config['loglevel']

Rdb = Redis.new(host: "redis")

PowerMap = {0=>0,3=>1,7=>2,10=>3,13=>4,17=>5,20=>6,23=>7,27=>8,30=>9,33=>10,37=>11,40=>12,43=>13,47=>14,50=>15,53=>16,57=>17,60=>18}

def query_wspr(callsign,ssid,flight_id,channel,slot_a,slot_b)
  ClickHouse.config do |config|
    config.logger = LOG #Logger.new(STDOUT)
    config.adapter = :net_http
    config.database = 'wspr'
    config.url = 'http://db1.wspr.live:80'
    config.timeout = 60
    config.open_timeout = 3
    config.ssl_verify = false
    config.headers = {}
  end
  @connection = ClickHouse::Connection.new(ClickHouse.config)
  spots = @connection.select_all("select * from wspr.rx where (tx_sign like '#{flight_id}_#{channel}%' or tx_sign='#{callsign}') and time > subtractMinutes(now(), 20);")
 
  LOG.debug "#{callsign}-#{ssid} query returned: #{spots.size}"
  spots.each {|p| LOG.debug "#{p['time']} #{p['tx_sign']} #{p['rx_sign']}"}

  return spots
end

def primary_spots(callsign,spots,slot_a)
  p = []
  spots.each do |spot|
    if spot['time'].min % 10 == slot_a && spot['tx_sign'] == callsign
      p << {time: spot['time'],loc: spot['tx_loc'], rx_sign: spot['rx_sign']}
    end
  end
  return p
end

def secondary_spots(callsign,ssid,spots,pspots,slot_b)
  balloon_reports = {}
  pspots.each do |p|
    key = "#{callsign}-#{ssid}-#{p[:time]}"
    balloon_reports[key] = {time: p[:time], callsign: callsign, grid: p[:loc], ssid: ssid } if balloon_reports[key] == nil
    if balloon_reports[key][:altitude].nil?
      spots.each do |s|
        if s['tx_sign'] =~ /^0|1|Q.*/ && #only consider telemetry spots
            s['time'].min % 10 == slot_b && #time matches slot_b 
            s['time'].to_time - p[:time].to_time == 120 && #spots match on timing 
            s['rx_sign'] == p[:rx_sign] #spots match on rx callsign
          decoded_call = decode_call(s['tx_sign'])
          balloon_reports[key][:altitude] = decoded_call[:altitude]
          balloon_reports[key][:grid] = balloon_reports[key][:grid] + decoded_call[:grid_56]
          decoded_grid_power = decode_grid_power(s['tx_loc'],s['power'])
          decoded_grid_power.each_key {|k| balloon_reports[key][k] = decoded_grid_power[k]}
          break
        end
      end
    end
  end
  return balloon_reports
end

def decode_call(tcall)
  a = []
  a[0] = tcall[1].to_i(36)*26**3
  a[1] = (tcall[3].to_i(36)-10)*26**2
  a[2] = (tcall[4].to_i(36)-10)*26
  a[3] = tcall[5].to_i(36)-10

  grid_5=a.sum/(24*1068)
  grid_6=a.sum-grid_5*(24*1068)
  altitude = (grid_6-(grid_6/1068)*1068)*20

  grid_6 = grid_6/1068
  grid_56 =(grid_5+10).to_s(36) + (grid_6+10).to_s(36)

  return {altitude: altitude, grid_56: grid_56}
end

def decode_grid_power(tgrid,tpower)
  decoded = {}
  a = []
  a[0] = (tgrid[0].to_i(36)-10)*18*10*10*19
  a[1] = (tgrid[1].to_i(36)-10)*10*10*19
  a[2] = (tgrid[2].to_i(36))*10*19
  a[3] = (tgrid[3].to_i(36))*19
  a[4] = PowerMap[tpower.to_i] 

  t1=a.sum/6720
  t2=t1*2+457
  t3=t2*5/1024
  decoded[:temperature]=(t2*500/1024)-273

  b1=a.sum-t1*6720
  b2=b1/168
  b3=b2*10+614
  decoded[:battery]=b3*5/1024

  g1=a.sum-t1*6720
  g2=(g1/168).floor
  g3=g1-g2*168
  g4=(g3/4).floor
  decoded[:speed]=g4*2

  r=g3-g4*4
  decoded[:gps]=(r/2).floor
  decoded[:sats]=r%2

  return decoded
end

def format_aprs(aprs_callsign,b)
  if DX::Grid.valid?(b[:grid]) 
    latitude,longitude = DX::Grid.decode(b[:grid])
    longitude = longitude.abs
    lat_D = latitude.to_i
    lon_D = longitude.to_i
    lat_M = (latitude % 1)*60
    lon_M = (longitude % 1)*60
    time = b[:time].strftime("%d%H%Mz")
    speed = b[:speed].nil? ? 0 : (b[:speed] * 1.94)
    altitude = b[:altitude].nil? ? 0 : (b[:altitude] * 3.28)
    out = "%s>APRS:;%6s-%0.2i*%s%02d%05.2fN/%03d%05.2fWO001/%03d/A=%06d" % [aprs_callsign,
                                                                            b[:callsign],
                                                                            b[:ssid],
                                                                            time,
                                                                            lat_D, 
                                                                            lat_M, 
                                                                            lon_D, 
                                                                            lon_M,
                                                                            speed,
                                                                            altitude]
  else
    out = nil
  end
  LOG.info out
  return out
end

def send_aprs(packets)
  s = TCPSocket.new Config['aprs']['server'], Config['aprs']['port']
  s.puts "user #{Config['aprs']['callsign']} pass #{Config['aprs']['passcode']}"
  packets.each do |packet| 
    unless Rdb.exists?("aprs_sent_#{packet[:key]}")
      s.puts packet[:data] 
      Rdb.set("aprs_sent_#{packet[:key]}",packet[:data], {ex: (Time.now + (86400*30)).to_i})
    end
  end
  s.close
end

reports = {}
Config['balloons'].each do |b| 
  all_spots = query_wspr(b['callsign'], b['ssid'], b['flight_id'], b['channel'], b['slot_a'], b['slot_b'])
  slot_a_spots = primary_spots(b['callsign'],all_spots,b['slot_a'])
  reports.merge! secondary_spots(b['callsign'],b['ssid'],all_spots,slot_a_spots,b['slot_b'])
end

packets = []
reports.each_pair do |k,r|
  LOG.debug r.inspect
  packets << {key: k, data: format_aprs(Config['aprs']['callsign'],r)}
end
send_aprs(packets) if Config['aprs']['send_aprs']

