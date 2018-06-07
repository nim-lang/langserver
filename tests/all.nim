import
  langserver/client, json

var c = initLspClient("tee test-session.log")
c.sendFrame("""{"event": "foo", "data": 10}""")
c.sendFrame("""{"event": "bar", "file": "bar.txt"}""")
c.sendFrame("""{"event": "end"}""")

for f in c.frames:
  var event = f["event"]
  if $event == "\"end\"": break
  echo event
