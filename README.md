# Golf Sim

3D golf simulator for iOS (SwiftUI + SceneKit + CoreMotion + CoreBluetooth). No external assets.

## Build the unsigned .ipa
1. Push this folder to a tool (ex. codemagic)
2. Open the **Actions** tab -> "Build unsigned IPA" 
3. Download the `GolfSim-unsigned-ipa` artifact, unzip it, and sideload `GolfSim.ipa` with SideStore / AltStore.

## BLE controller protocol
Service `12345678-1234-5678-1234-567812345678`, notify characteristic `87654321-4321-6789-4321-678943218765`.
One 20-byte little-endian packet per swing:

| bytes | type | field |
|---|---|---|
| 0 | u8 | version (1) |
| 1 | u8 | club id (0 Driver, 1 3W, 2 5i, 3 7i, 4 9i, 5 PW, 6 SW, 7 Putter) |
| 2-3 | u16 | sequence |
| 4-5 | u16 | clubhead speed mph x10 |
| 6-7 | u16 | ball speed mph x10 |
| 8-9 | i16 | launch angle deg x10 |
| 10-11 | i16 | azimuth deg x10 (left -, right +) |
| 12-13 | u16 | peak acceleration g x100 |
| 14-15 | u16 | spin rpm |
| 16-19 | u32 | ms since device boot |

Web Bluetooth example:
```js
const dev = await navigator.bluetooth.requestDevice({ filters: [{ services: ['12345678-1234-5678-1234-567812345678'] }] });
const svc = await (await dev.gatt.connect()).getPrimaryService('12345678-1234-5678-1234-567812345678');
const ch = await svc.getCharacteristic('87654321-4321-6789-4321-678943218765');
await ch.startNotifications();
ch.addEventListener('characteristicvaluechanged', e => {
  const v = e.target.value;
  console.log({ clubheadMph: v.getUint16(4, true) / 10, ballMph: v.getUint16(6, true) / 10,
                launchDeg: v.getInt16(8, true) / 10, azimuthDeg: v.getInt16(10, true) / 10 });
});
```
