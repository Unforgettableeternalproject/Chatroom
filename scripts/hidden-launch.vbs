' Launch a command with no visible console window, without owning it.
'
' ASCII ONLY, no BOM. wscript reads .vbs with the system ANSI code page --
' the same trap that produced two red lines from the .cmd files until
' 2026-09-11. See tests/test_cmd_scripts_encoding.py.
'
' Why this file has to exist:
' "detached AND hidden" is not reachable from Dart on Windows.
' Process.start(mode: detached) maps to DETACHED_PROCESS, and a console app
' started that way allocates a *new* console of its own -- that empty black
' window is exactly what it produces. CREATE_NO_WINDOW would avoid it, but
' Dart exposes no such flag. wscript.exe is a GUI host, so Run(cmd, 0, False)
' starts the target with a hidden console and returns immediately, leaving
' the process alive after both this script and the App are gone.
'
' Measured 2026-09-11 (probe reported its own GetConsoleWindow/IsWindowVisible):
'   cmd /c start ""     + DETACHED  -> visible = 1
'   cmd /c start "" /b  + DETACHED  -> visible = 1   (/b does not help here:
'                                      the parent has no console to inherit,
'                                      so cmd allocates one anyway)
'   cmd /c <script>     + DETACHED  -> visible = 1
'   wscript + Run(..,0) + DETACHED  -> visible = 0   <- this file
Option Explicit
Dim sh, line, i
If WScript.Arguments.Count = 0 Then
  WScript.Quit 1
End If
Set sh = CreateObject("WScript.Shell")
' Tell the launched script it has no visible console. run-tunnel.cmd uses this
' to skip its `pause` -- a pause inside a hidden window waits forever on a key
' nobody can press, leaving an invisible cmd behind on every failed start.
sh.Environment("PROCESS")("CHATROOM_HIDDEN") = "1"
line = ""
For i = 0 To WScript.Arguments.Count - 1
  line = line & """" & WScript.Arguments(i) & """ "
Next
' 0 = hidden window, False = do not wait for it to finish
sh.Run line, 0, False
