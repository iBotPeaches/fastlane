<p align="center">
  <img src="/img/actions/pem.png" width="250">
</p>

###### Automatically generate and renew your push notification profiles

Tired of manually creating and maintaining your push notification profiles for your iOS apps? Tired of generating a _pem_ file for your server?

_pem_ does all that for you, just by simply running _pem_.

_pem_ creates new .pem, .cer, and .p12 files to be uploaded to your push server if a valid push notification profile is needed. _pem_ does not cover uploading the file to your server.

To automate iOS Provisioning profiles you can use [_match_](https://docs.fastlane.tools/actions/match/).

-------

<p align="center">
    <a href="#features">Features</a> &bull;
    <a href="#usage">Usage</a> &bull;
    <a href="#authentication-keys-instead-of-certificates">Authentication keys</a> &bull;
    <a href="#how-does-it-work">How does it work?</a>
</p>

-------

<h5 align="center"><em>pem</em> is part of <a href="https://fastlane.tools">fastlane</a>: The easiest way to automate beta deployments and releases for your iOS and Android apps.</h5>

# Features
Well, it's actually just one: Generate the _pem_ file for your server.

Check out this gif:

![img/actions/PEMRecording.gif](/img/actions/PEMRecording.gif)

# Usage

```no-highlight
fastlane pem
```

Yes, that's the whole command!

This does the following:

- Create a new signing request
- Create a new push certification
- Downloads the certificate
- Generates a new ```.pem``` file in the current working directory, which you can upload to your server

Note that _pem_ will never revoke your existing certificates. _pem_ can't download any of your existing push certificates, as the private key is only available on the machine it was created on.

If you already have a push certificate enabled, which is active for at least 30 more days, _pem_ will not create a new certificate. If you still want to create one, use the `force`:

```no-highlight
fastlane pem --force
```

You can pass parameters like this:

```no-highlight
fastlane pem -a com.krausefx.app -u username
```

If you want to generate a development certificate instead:

```no-highlight
fastlane pem --development
```

If you want to generate a Website Push certificate:

```no-highlight
fastlane pem --website_push
```

If you want to generate a VoIP Services certificate (the type PushKit requires):

```no-highlight
fastlane pem --voip_push
```

Set a password for your `p12` file:

```no-highlight
fastlane pem -p "MyPass"
```

You can specify a name for the output file:

```no-highlight
fastlane pem -o my.pem
```

To get a list of available options run:

```no-highlight
fastlane action pem
```

### Note about empty `p12` passwords and Keychain Access.app

_pem_ will produce a valid `p12` without specifying a password, or using the empty-string as the password.
While the file is valid, the Mac's Keychain Access will not allow you to open the file without specifying a passphrase.

Instead, you may verify the file is valid using OpenSSL:

```no-highlight
openssl pkcs12 -info -in my.p12
```

If you need the `p12` in your keychain, perhaps to test push with an app like [Knuff](https://github.com/KnuffApp/Knuff) or [Pusher](https://github.com/noodlewerk/NWPusher), you can use `openssl` to export the `p12` to _pem_ and back to `p12`:

```no-highlight
% openssl pkcs12 -in my.p12 -out my.pem
Enter Import Password:
  <hit enter: the p12 has no password>
MAC verified OK
Enter your pem passphrase:
  <enter a temporary password to encrypt the pem file>

% openssl pkcs12 -export -in my.pem -out my-with-passphrase.p12
Enter pass phrase for temp.pem:
  <enter the temporary password to decrypt the pem file>

Enter Export Password:
  <enter a password for encrypting the new p12 file>
```

## Environment Variables

Run `fastlane action pem` to get a list of available environment variables.

# Authentication keys instead of certificates

A push certificate expires after a year, only covers one bundle identifier and comes in separate development and production flavours. Apple's token based alternative is an **APNs authentication key**: a single `.p8` file that never expires, covers the sandbox and the production environment at once and is shared by every app of your team.

To create one, or to download the one you already have:

```no-highlight
fastlane pem auth_key
```

This writes `AuthKey_<KEY ID>.p8` to the output path. Together with the key ID (part of the file name) and your team ID, that is everything a server needs to sign APNs requests.

To see every authentication key of your team, or to revoke one:

```no-highlight
fastlane pem list_auth_keys
fastlane pem revoke_auth_key --key_id ABCD123456
```

Revoking asks for a confirmation first. On CI, where nobody can answer, pass `--skip_confirmation`.

In a `Fastfile`, use the `get_push_auth_key` action. It sets `PEM_AUTH_KEY_PATH`, `PEM_AUTH_KEY_ID` and `PEM_AUTH_KEY_TEAM_ID` in the lane context.

```ruby
get_push_auth_key(
  key_name: "Push notifications",
  output_path: "./keys"
)
```

Three things are worth knowing before you switch:

- **Apple only lets you download a `.p8` once.** There is no way to get it again. _pem_ reuses the file in `output_path` when it is already there, and refuses to silently create a second key when the existing one can no longer be downloaded — it tells you to supply the file, to revoke the key, or to pass `--force` if you really want an extra key. Apple limits how many authentication keys a team can hold, so `--force` is not something to put in a lane.
- **A key is team wide.** The `app_identifier` option does not apply to it, and revoking a key stops push notifications for every app and every server that uses it.
- **Authentication keys only exist on the Developer Portal**, which has no App Store Connect API. _pem_ therefore always signs in with your Apple ID for these commands — on CI you need a `FASTLANE_SESSION`, an App Store Connect API key will not work.

# How does it work?

_pem_ uses [_spaceship_](https://spaceship.airforce) to communicate with the Apple Developer Portal to request a new push certificate for you.

## How is my password stored?
_pem_ uses the [password manager](https://github.com/fastlane/fastlane/tree/master/credentials_manager) from _fastlane_. Take a look the [CredentialsManager README](https://github.com/fastlane/fastlane/tree/master/credentials_manager) for more information.
