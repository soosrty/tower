"""Cross-check CoreDevice records against Xcode's physical-device inventory."""
import json
import sys


def physical_devices(devices, inventory):
    physical_ids = {
        item['identifier'] for item in inventory
        if item.get('simulator') is False and item.get('available') is True
        and item.get('platform') == 'com.apple.platform.iphoneos'
    }
    # iPads share the iphoneos platform; a paired iPad on the network must
    # not make an attached iPhone ambiguous.
    return [device for device in devices
            if device.get('hardwareProperties', {}).get('udid') in physical_ids
            and device.get('hardwareProperties', {}).get('deviceType') == 'iPhone']


if __name__ == '__main__':
    with open(sys.argv[1]) as stream:
        devices = json.load(stream)['result']['devices']
    with open(sys.argv[2]) as stream:
        inventory = json.load(stream)
    candidates = physical_devices(devices, inventory)
    if len(candidates) != 1:
        sys.exit('需要且只能连接一台可用的实体 iPhone；模拟器不算真机')
    print(candidates[0]['hardwareProperties']['udid'])
