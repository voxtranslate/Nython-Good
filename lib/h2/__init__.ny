# nython: module    (a package: h2.connection, h2.events, h2.frame, h2.client, h2.server ...)
# nython: python    (Python's binding rule: a name a function binds is its local - round 85)
# lib/h2 - HTTP/2 (RFC 9113; round 86). Not in CPython's standard library:
# the API is python-hyper's `h2` package (H2Connection and its events, a
# sans-I/O state machine), with hyperframe's frames as h2.frame and RFC 7541
# header compression in lib/hpack.ny. Around it, I/O:
#
#   h2.connection   H2Connection: the whole protocol as a state machine -
#                   bytes in (receive_data -> events), bytes out
#                   (data_to_send); no sockets, no threads
#   h2.config       H2Configuration
#   h2.events       RequestReceived, ResponseReceived, DataReceived,
#                   StreamEnded, StreamReset, WindowUpdated, SettingsAcknowledged,
#                   RemoteSettingsChanged, PingReceived, PingAckReceived,
#                   ConnectionTerminated, TrailersReceived, ...
#   h2.errors       ErrorCodes;  h2.exceptions  ProtocolError and the rest
#   h2.settings     SettingCodes, Settings, ChangedSetting
#   h2.frame        the ten frame types of RFC 9113 (+ ALTSVC, RFC 9218's
#                   PRIORITY_UPDATE, extension frames), hyperframe's API
#   h2.priority     RFC 9218 Extensible Prioritization: the Priority field
#                   (urgency, incremental) and a server-side scheduler
#   h2.client       an asyncio client: connect() (TLS with ALPN "h2", or
#                   prior-knowledge h2c), request(), multiplexed streams
#   h2.server       an asyncio server: serve(handler, host, port, ssl=...),
#                   each stream a task, flow control and RFC 9218 scheduling
#   h2.sync         a blocking client session over a socket (what
#                   http.client and urllib.request use with http2=True)
#
# The sans-I/O modules (all but client, server, sync and _aio) are written in
# the subset of the language CPython also runs: vm_audit123 drives them under
# python3 too.

__version__ = "4.4.1"
