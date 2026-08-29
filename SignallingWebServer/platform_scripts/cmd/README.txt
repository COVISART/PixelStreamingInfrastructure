How to use files in this directory:

- setup.bat : Ensures the correct node is installed and builds the frontend if it isn't already
- start.bat : Starts the signalling server with basic settings
- common.bat : Contains a bunch of helper functions for the contained scripts. Shouldn't be run directly.

The following are provided as handy shortcuts but mostly leverage start.bat functionality
- start_turn.bat : Starts the turn server only with basic settings
- start_with_stun.bat : Starts the signalling server with basic STUN settings
- start_with_turn.bat : Starts the TURN server and then the signalling server with STUN and TURN parameters

To keep the signalling server running without anyone logged in, install it as a Windows
service instead of using start.bat. Both scripts ask for elevation if they need it.
- install_service.bat : Sets everything up and installs the signalling server as a service that starts at boot
- uninstall_service.bat : Stops and removes that service

The TURN options mirror the start.bat ones, and -StartTurn installs the bundled coturn as
a second service. So this start.bat command:
    start.bat --start-turn --turn 192.168.1.50:19303 --publicip 203.0.113.7
becomes:
    install_service.bat -StartTurn -TurnServer 192.168.1.50:19303 -PublicIp 203.0.113.7
- install_service.ps1 / uninstall_service.ps1 : The PowerShell scripts the .bat files call. Run them
                          directly from an Administrator prompt for the full set of options, or run
                          "Get-Help .\install_service.ps1 -Detailed" to see them.

Tips:

- You can provide --help to start.bat to get a list of customizable arguments.
- Values passed to these scripts cannot contain ^ or ! characters. cmd.exe
  doubles a caret when the scripts hand their arguments to common.bat, and
  strips an exclamation mark under delayed expansion, so a TURN password such
  as "pass!word" arrives as "password" with no error. Choose credentials
  without those two characters.
