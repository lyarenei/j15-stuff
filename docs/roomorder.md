# roomorder

Makes the robot clean selected rooms in the order you selected them. Status:
**untested** on the robot. If you use the [patched Valetudo](valetudo.md), you
don't need it (see below).

## The problem

When you select several rooms, Valetudo sends them in your order, but the
firmware's `manager_node` throws that order away and cleans in its own order
(rooms with a stored per-room sequence number first, the rest by distance). So
the order looks random.

## Two fixes

| | Patched Valetudo | roomorder |
|---|---|---|
| What it does | Writes sequence numbers 1..N on the selected rooms before the clean, and restores the old values afterwards | Changes one instruction in a copy of `manager_node`, so the request order is kept |
| Touches on the robot | changes only the rooms' stored sequence numbers (restored after the clean) | bind-mounts a patched binary over the vendor one, restarts all nodes |
| Status | Verified on the robot. | Untested. |
| After a firmware update | still works if the layout didn't change | has to be re-created (the installer refuses other versions) |

They don't conflict. The patched Valetudo detects the `roomorder` mount (it
sees `/usr/navi/manager_node` in `/proc/mounts`) and then sends the order
as is, without writing sequence numbers.

Use the Valetudo fix if you run the patched Valetudo. `roomorder` is for when
you want the order without Valetudo writing to the robot's room map, or you
don't use the patched build.

Neither can give a strict order in "customized clean" mode: rooms set to
vacuum only are moved to the front.

## Requirements

- A rooted J15 with SSH access as `root`.
- The firmware version the patch was written for. The installer checks the
  checksum of `manager_node` and does nothing on any other version.
- The robot is not in vendor debug mode (`/oem/midea_autorun` absent), and is
  docked or idle.
- If some rooms already have a non-zero per-room sequence number (set by the
  Midea app), the firmware still sorts those among themselves.

## Install, status, uninstall

```sh
./install.sh roomorder-install   192.168.1.50 [ssh options]
./install.sh roomorder-status    192.168.1.50 [ssh options]   # mount active? running binary? boot hook? log
./install.sh roomorder-uninstall 192.168.1.50 [ssh options]   # unmounts, restarts manager_node, removes files
```

Install copies `/usr/navi/manager_node` to `/userdata/roomorder`, changes 4
bytes in the copy, adds a boot hook and bind-mounts the copy over the original.
The vendor binary is never shipped.

Installing, uninstalling and every boot **restart all the robot's nodes**
(`/usr/bin/track` restarts the whole stack when `manager_node` dies; about a
minute). Don't do it during a clean.

## Configuration

None.

## Limits and caveats

- Whole-house cleans are not affected.
- Re-create the patch after a firmware update. The boot hook skips the mount
  when the checksum doesn't match.
- If you also install [obstaclegap](obstaclegap.md), each one restarts the
  nodes at boot.
- Untested: restarting `manager_node` this way was worked out by reading the
  firmware, not observed.

## How it was found

Why the order is lost, the patched instruction and how nodes get restarted:
wiki page
[room-order-investigation](https://github.com/lyarenei/j15-stuff/wiki/room-order-investigation).
