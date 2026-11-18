import time
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, DurabilityPolicy, HistoryPolicy
from px4_msgs.msg import VehicleStatus, VehicleLocalPosition, BatteryStatus

PX4_QOS = QoSProfile(
    reliability=ReliabilityPolicy.BEST_EFFORT,
    durability=DurabilityPolicy.TRANSIENT_LOCAL,
    history=HistoryPolicy.KEEP_LAST,
    depth=1,
)


class FakePX4Telemetry(Node):
    def __init__(self):
        super().__init__("fake_px4_telemetry")
        self.pub_status = self.create_publisher(VehicleStatus, "/fmu/out/vehicle_status", PX4_QOS)
        self.pub_pos = self.create_publisher(VehicleLocalPosition, "/fmu/out/vehicle_local_position", PX4_QOS)
        self.pub_battery = self.create_publisher(BatteryStatus, "/fmu/out/battery_status", PX4_QOS)

        self.arming_state = VehicleStatus.ARMING_STATE_ARMED
        self.nav_state = VehicleStatus.NAVIGATION_STATE_OFFBOARD
        self.position = [0.0, 0.0, -2.0]  # NED frame: 2.0m altitude
        self.velocity = [0.0, 0.0, 0.0]
        self.battery_remaining = 0.85  # 85%
        self.battery_warning = BatteryStatus.WARNING_NONE

    def publish_tick(self):
        now_us = int(time.monotonic() * 1e6)

        status = VehicleStatus()
        status.timestamp = now_us
        status.arming_state = self.arming_state
        status.nav_state = self.nav_state
        self.pub_status.publish(status)

        pos = VehicleLocalPosition()
        pos.timestamp = now_us
        pos.xy_valid = True
        pos.z_valid = True
        pos.v_xy_valid = True
        pos.v_z_valid = True
        pos.x, pos.y, pos.z = [float(v) for v in self.position]
        pos.vx, pos.vy, pos.vz = [float(v) for v in self.velocity]
        self.pub_pos.publish(pos)

        bat = BatteryStatus()
        bat.timestamp = now_us
        bat.connected = True
        bat.remaining = float(self.battery_remaining)
        bat.warning = self.battery_warning
        self.pub_battery.publish(bat)