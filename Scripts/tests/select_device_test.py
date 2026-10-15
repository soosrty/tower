import importlib.util
import unittest
from pathlib import Path

class SelectionTests(unittest.TestCase):
    def test_simulator_is_never_a_physical_device(self):
        spec = importlib.util.spec_from_file_location('selector', Path(__file__).parents[1] / 'select_device.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        devices = [{'identifier': 'sim', 'hardwareProperties': {'udid': 'sim'}}, {'identifier': 'phone', 'hardwareProperties': {'udid': 'physical', 'deviceType': 'iPhone'}}]
        inventory = [{'identifier': 'sim', 'simulator': True, 'available': True, 'platform': 'com.apple.platform.iphoneos'}]
        self.assertEqual(module.physical_devices(devices, inventory), [])
        inventory.append({'identifier': 'physical', 'simulator': False, 'available': True, 'platform': 'com.apple.platform.iphoneos'})
        self.assertEqual(module.physical_devices(devices, inventory), [devices[1]])
        # A paired iPad shares the platform but is not the install target.
        devices.append({'identifier': 'tablet', 'hardwareProperties': {'udid': 'ipad', 'deviceType': 'iPad'}})
        inventory.append({'identifier': 'ipad', 'simulator': False, 'available': True, 'platform': 'com.apple.platform.iphoneos'})
        self.assertEqual(module.physical_devices(devices, inventory), [devices[1]])

if __name__ == '__main__':
    unittest.main()
