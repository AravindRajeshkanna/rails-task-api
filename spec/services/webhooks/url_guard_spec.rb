require "rails_helper"

RSpec.describe Webhooks::UrlGuard do
  describe ".resolve!" do
    it "returns the address for a public host" do
      stub_dns("hooks.example.com" => "203.0.113.10")

      expect(described_class.resolve!("hooks.example.com")).to eq("203.0.113.10")
    end

    it "accepts public IP literals without a DNS lookup" do
      expect(Resolv).not_to receive(:getaddresses)

      expect(described_class.resolve!("93.184.216.34")).to eq("93.184.216.34")
    end

    {
      "loopback" => "127.0.0.1",
      "localhost v6" => "::1",
      "cloud metadata endpoint" => "169.254.169.254",
      "RFC1918 10/8" => "10.1.2.3",
      "RFC1918 172.16/12" => "172.20.0.5",
      "RFC1918 192.168/16" => "192.168.1.1",
      "carrier-grade NAT" => "100.64.0.1",
      "unspecified" => "0.0.0.0",
      "IPv6 unique local" => "fd00::1",
      "IPv6 link local" => "fe80::1",
      "IPv4-mapped loopback" => "::ffff:127.0.0.1",
      "multicast" => "224.0.0.1"
    }.each do |label, address|
      it "blocks #{label} (#{address})" do
        expect { described_class.resolve!(address) }.to raise_error(described_class::BlockedAddress)
      end
    end

    it "blocks hostnames that resolve to private addresses (DNS pointing inward)" do
      stub_dns("internal.attacker.example" => "10.0.0.7")

      expect { described_class.resolve!("internal.attacker.example") }
        .to raise_error(described_class::BlockedAddress, /non-public/)
    end

    it "blocks a host if any of its addresses is private (mixed answers)" do
      stub_dns("mixed.example" => [ "203.0.113.10", "127.0.0.1" ])

      expect { described_class.resolve!("mixed.example") }.to raise_error(described_class::BlockedAddress)
    end

    it "blocks hosts that do not resolve" do
      stub_dns({})

      expect { described_class.resolve!("nxdomain.example") }.to raise_error(described_class::BlockedAddress, /does not resolve/)
    end

    it "allows private networks when explicitly enabled (development)" do
      allow(Rails.configuration.x.webhooks).to receive(:allow_private_networks).and_return(true)

      expect(described_class.resolve!("127.0.0.1")).to eq("127.0.0.1")
    end
  end
end
