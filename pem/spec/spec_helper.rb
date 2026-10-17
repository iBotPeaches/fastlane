def pem_stub_spaceship
  expect(Spaceship).to receive(:login).and_return(nil)
  allow(Spaceship).to receive(:client).and_return("client")
  expect(Spaceship.client).to receive(:select_team).and_return(nil)
  expect(Spaceship.certificate).to receive(:all).and_return([])

  csr = "csr"
  pkey = "pkey"

  expect(Spaceship.certificate).to receive(:create_certificate_signing_request).and_return([csr, pkey])
  expect(pkey).to receive(:to_pem).twice.and_return("to_pem")
end

def pem_stub_spaceship_cert(platform: 'ios', voip_push: false)
  csr = "csr"
  cert = "cert"
  x509 = "x509"

  if voip_push
    expect(Spaceship.certificate.voip_push).to receive(:create!).with(csr: csr, bundle_id: "com.krausefx.app").and_return(cert)
  else
    case platform
    when 'macos'
      expect(Spaceship.certificate.mac_production_push).to receive(:create!).with(csr: csr, bundle_id: "com.krausefx.app").and_return(cert)
    else
      expect(Spaceship.certificate.production_push).to receive(:create!).with(csr: csr, bundle_id: "com.krausefx.app").and_return(cert)
    end
  end

  expect(cert).to receive(:download).and_return(x509)
  expect(x509).to receive(:to_pem).and_return("to_pem")
end

def pem_stub_spaceship_login
  allow(Spaceship).to receive(:login).and_return(nil)
  client = double("client", select_team: nil, team_id: "ZZZTEAMID")
  allow(Spaceship).to receive(:client).and_return(client)
end

def pem_stub_key(id: "ABCD123456", name: "fastlane APNs Key", can_download: false, can_revoke: true, apns: true)
  double("key",
         id: id,
         name: name,
         can_download: can_download,
         can_revoke: can_revoke,
         has_apns?: apns)
end
