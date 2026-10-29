module DnsHelpers
  # stub_dns("hooks.example.com" => "203.0.113.10") makes name resolution deterministic and offline.
  def stub_dns(mapping)
    allow(Resolv).to receive(:getaddresses).and_return([])
    mapping.each do |host, addresses|
      allow(Resolv).to receive(:getaddresses).with(host).and_return(Array(addresses))
    end
  end
end

RSpec.configure { |config| config.include DnsHelpers }
