# wspr-hab-telemetry
This is still a work in progress, but is functional in it's current state.
I owe credit to David SM3ULC who wrote a python version of this [here](https://github.com/sm3ulc/hab-wspr). I used some of the math that he worked
out for decoding the telemetry.  Also [this](https://www.qrp-labs.com/images/ultimate3builder/ve3kcl/s4/308d.xls)
spreadsheet was indispensible for checking the accuracy of my decoding logic.
I'm not sure who gets credit for the spreadsheet, but I suspect it's the most
prolific balloon guy, Dave, VE3KCL. This dude launches balloons that circle the
earth multiple times, one is on it's 16th or 17th trip as I write this (Sept
24, 2021).

Here's the basic process:
- First this queries a live WSPR spot database [here](https://wspr.live).
- Then looks for telemetry using the "Special WSPR Telemetry Protocol described [here](https://www.qrp-labs.com/flights/s4.html) 
- Attempts to decode the telemetry. If a telemetry packet isn't found, it uses
  the coarse 4 digit maidenhead grid from the first spot for the next step, otherwise, uses the
decoded 6 digit maidenhead for a finer position.
- Constructs an APRS packet and sends it to an APRS port.

At home, I have Xastir and a local APRSC instance running, this feeds my local APRSC which Xastir is
listening on, and plots the balloons on my Xastir map. I'm not sending anything
to APRS-IS currently. As far as I understand, only designated people are
actually sending WSPR HAB spots to APRS-IS so they're seen on APRS.FI. 

## Update: now uses REDIS
I've added support for REDIS. Now it will keep track of APRS packets sent and not send duplicates.

## Things I still would like to do:
- Build an embedded Google Map page that maps the balloons, and uses the above Redis
  to get periodic updates
- Keep the last Grid value in REDIS. If, on the most recent update we only received a 4 digit grid, and it matched a previously received 6 digit grid, then send a new APRS packet but use the 6 digit grid position as long as it's still within the larger 4 digit grid. 
