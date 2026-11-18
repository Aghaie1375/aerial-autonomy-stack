import time
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, DurabilityPolicy, HistoryPolicy
from std_msgs.msg import String
from px4_msgs.msg import (
    OffboardControlMode,
    TrajectorySetpoint,
    VehicleCommand,
    VehicleLocalPosition,
    BatteryStatus,
)

PX4_QOS = QoSProfile(
    reliability=ReliabilityPolicy.BEST_EFFORT,
    durability=DurabilityPolicy.TRANSIENT_LOCAL,
    history=HistoryPolicy.KEEP_LAST,
    depth=1,
)


class MissionBrainNode(Node):
    def __init__(self):
        super().__init__("mission_brain_node")
        self.target_ned = [0.0, 0.0, -2.0]  # Default hover at 2.0m altitude (NED)
        self.land_triggered = False

        # Publishers to PX4
        self.pub_offboard = self.create_publisher(OffboardControlMode, "/fmu/in/offboard_control_mode", PX4_QOS)
        self.pub_setpoint = self.create_publisher(TrajectorySetpoint, "/fmu/in/trajectory_setpoint", PX4_QOS)
        self.pub_cmd = self.create_publisher(VehicleCommand, "/fmu/in/vehicle_command", PX4_QOS)

        # Subscribers from Perception & PX4
        self.create_subscription(String, "/detections", self._on_detection, 10)
        self.create_subscription(BatteryStatus, "/fmu/out/battery_status", self._on_battery, PX4_QOS)
        self.create_subscription(VehicleLocalPosition, "/fmu/out/vehicle_local_position", self._on_pos, PX4_QOS)

        # 10 Hz control loop
        self.create_timer(0.1, self._control_loop)

    def _on_detection(self, msg: String):
        if "target_detected:" not in msg.data:
            return
        try:
            coords = dict(item.split("=") for item in msg.data.split(":")[1].split(","))
            self.target_ned[0] = float(coords["x"])
            self.target_ned[1] = float(coords["y"])
        except (ValueError, KeyError):
            self.get_logger().warning(f"Malformed detection payload: {msg.data}")

    def _on_battery(self, msg: BatteryStatus):
        if msg.warning >= BatteryStatus.WARNING_CRITICAL and not self.land_triggered:
            self.land_triggered = True
            cmd = VehicleCommand()
            cmd.timestamp = int(time.monotonic() * 1e6)
            cmd.command = VehicleCommand.VEHICLE_CMD_NAV_LAND
            cmd.target_system = 1
            cmd.target_component = 1
            cmd.source_system = 1
            cmd.source_component = 1
            cmd.from_external = True
            self.pub_cmd.publish(cmd)
            self.get_logger().warn("Critical battery! Sent NAV_LAND command.")

    def _on_pos(self, msg: VehicleLocalPosition):
        pass

    def _control_loop(self):
        now_us = int(time.monotonic() * 1e6)

        ob = OffboardControlMode()
        ob.timestamp = now_us
        ob.position = True
        self.pub_offboard.publish(ob)

        if not self.land_triggered:
            sp = TrajectorySetpoint()
            sp.timestamp = now_us
            sp.position = [float(v) for v in self.target_ned]
            sp.yaw = 0.0
            self.pub_setpoint.publish(sp)


def main():
    rclpy.init()
    node = MissionBrainNode()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()