# OpenClash config helper for cfbest (OpenClash ships ruby with the yaml module).
#   ruby yaml.rb list <file>                 one proxy per line: name server port tls host path network
#   ruby yaml.rb set <file> <name> <server>  exit 10 if changed, 0 if already set, 2 if not found
require 'yaml'

cmd, file, name, server = ARGV
y = begin
  YAML.load_file(file)
rescue StandardError
  nil
end
proxies = (y.is_a?(Hash) && y['proxies'].is_a?(Array)) ? y['proxies'].select { |p| p.is_a?(Hash) } : []

def clean(v)
  v.to_s.gsub(/[\t\r\n]/, ' ')
end

case cmd
when 'list'
  proxies.each do |p|
    ws = p['ws-opts'].is_a?(Hash) ? p['ws-opts'] : {}
    headers = ws['headers'].is_a?(Hash) ? ws['headers'] : {}
    grpc = p['grpc-opts'].is_a?(Hash) ? p['grpc-opts'] : {}
    network = (p['network'] || 'tcp').to_s
    tls = p['tls'] == true || %w[trojan].include?(p['type'].to_s)
    host = p['servername'] || p['sni'] || headers['Host'] || headers['host']
    path = ws['path'] || (grpc['grpc-service-name'] ? "/#{grpc['grpc-service-name']}/Tun" : nil) || '/'
    puts [p['name'], p['server'], p['port'], tls ? 1 : 0, host, path, network].map { |v| clean(v) }.join("\t")
  end
when 'set'
  p = proxies.find { |x| x['name'].to_s == name }
  exit 2 unless p
  exit 0 if p['server'].to_s == server
  # keep the original domain as SNI/Host, then point the proxy at the IP
  if p['servername'].nil? && p['sni'].nil? && !p['server'].to_s.match?(/\A[\d.]+\z/)
    p[p['type'].to_s == 'trojan' ? 'sni' : 'servername'] = p['server'].to_s
  end
  p['server'] = server
  tmp = "#{file}.cfbest.tmp"
  File.write(tmp, y.to_yaml)
  File.rename(tmp, file)
  exit 10
else
  exit 1
end
