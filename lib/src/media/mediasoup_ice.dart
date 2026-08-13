/// The three ICE types the mediasoup client needs from you but does not hand out.
///
/// `RTCIceServer`, `RTCIceTransportPolicy` and `RTCIceCredentialType` are
/// declared in `mediasfu_mediasoup_client`'s `src/handlers/handler_interface.dart`
/// and **nothing in the package exports them** — not the barrel, not
/// `transport.dart`, not `common/index.dart`. They are still the declared
/// parameter types of every API that accepts TURN servers:
/// `Device.createSendTransport`, `Device.createRecvTransport`, and
/// `Transport.updateIceServers`, which is what P7's `restart-ice` rotation will
/// call. There is no map-taking overload — the `…FromMap` constructors exist and
/// are worse, because they hardcode `iceServers: []` and would silently drop
/// Gather's TURN servers on the floor.
///
/// So the choice is not "implementation import or something cleaner", it is
/// "implementation import or no TURN", and no TURN means working fine in the
/// office and no media at all behind a symmetric NAT. This file exists so that
/// trade is made **once**, here, instead of once per call site.
///
/// If upstream moves or renames that file, this is the only file that breaks, and
/// it breaks at compile time. Worth an upstream one-line PR adding it to the
/// barrel; if we ever vendor the package (the original plan, dropped in favour of
/// pub), this file is what disappears.
library;

// ignore: implementation_imports
export 'package:mediasfu_mediasoup_client/src/handlers/handler_interface.dart'
    show RTCIceCredentialType, RTCIceServer, RTCIceTransportPolicy;
