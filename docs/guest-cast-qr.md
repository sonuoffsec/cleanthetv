# Guest-cast QR

A QR code on the TV's home screen that lets a guest join your Wi-Fi with one scan, so their phone is on the same
network as the TV and can cast to it.

## What it does, and what it does not

| It does | It does not |
|---|---|
| Show a QR that joins the Wi-Fi network the TV is **currently on** | Start screen mirroring by itself. No QR can; the phone's own Cast or Smart View button does that |
| Follow the network automatically when the TV changes Wi-Fi | Work on a network that is not in your list (the QR is hidden there on purpose) |
| Name the TV in the hint, from the TV's own device name | Learn a Wi-Fi password by itself. Android does not let any app read one |

## Set it up

In your theme's `config.json`:

```json
"wifi_qr_networks": [
  "MyHomeWiFi=my-home-password",
  "MyPhoneHotspot=my-hotspot-password"
]
```

Each entry is `network name=password`. The first `=` splits the two, so a password may contain `=`. Leave the password
empty (`"CafeWiFi="`) for an open network.

Then push the theme: `.\cleanthetv.ps1 theme -Theme <your theme>`. No rebuild is needed.

## For the guest

1. Scan the QR with the phone camera and tap to join the Wi-Fi.
2. Open **Cast**, **Smart View** or **Screen mirroring** on the phone and pick the TV.

## Security: read this

- **The QR contains the Wi-Fi password.** Anyone who can see the TV screen can scan it and join your network. Use it
  for a guest network or a hotspot you do not mind sharing, not for your main network in a shared space.
- The password is stored in your theme file and on the TV. **Never commit a theme with real passwords to Git.**
- To stop sharing, remove the entry and push the theme again.

## How it works

The launcher reads the connected SSID (the same way it labels the Wi-Fi button), looks it up in `wifi_qr_networks`, and
draws a standard Wi-Fi QR (`WIFI:T:WPA;S:<name>;P:<password>;;`) with ZXing. The special characters `\ ; , : "` are
escaped. When the network changes, the QR updates with the Wi-Fi button.

## Troubleshooting

- **No QR shows.** The TV's network is not in the list, or the name differs by one character or letter case.
- **The phone cannot join.** Check the password, and that a hotspot is switched on.
- **The phone joins but cannot find the TV.** Some routers isolate guest devices from each other (AP isolation).
  Turn that off, or use a hotspot.
