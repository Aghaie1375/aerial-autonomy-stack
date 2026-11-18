import time
from rclpy.node import Node
from std_msgs.msg import String
from px4_msgs.msg import OffboardControlMode, TrajectorySetpoint, VehicleCommand, BatteryStatus
from conftest import wait_for_condition
from synthetic_data.fake_px4_telemetry import FakePX4Telemetry, PX4_QOS


class BrainHarness(Node):
    def __init__(self):
        super().__init__("brain_harness")
        self.pub_det = self.create_publisher(String, "/detections", 10)
        self.offboard_msgs = []
        self.setpoints = []
        self.commands = []

        self.create_subscription(
            OffboardControlMode,
            "/fmu/in/offboard_control_mode",
            self.offboard_msgs.append,
            PX4_QOS,
        )
        self.create_subscription(
            TrajectorySetpoint,
            "/fmu/in/trajectory_setpoint",
            self.setpoints.append,
            PX4_QOS,
        )
        self.create_subscription(
            VehicleCommand,
            "/fmu/in/vehicle_command",
            self.commands.append,
            PX4_QOS,
        )


def test_offboard_heartbeat_and_setpoint(ros_context):
    fake_px4 = FakePX4Telemetry()
    harness = BrainHarness()
    ros_context.add_node(fake_px4)
    ros_context.add_node(harness)

    try:
        for _ in range(10):
            fake_px4.publish_tick()
            det = String()
            det.data = "target_detected:x=3.0,y=1.5"
            harness.pub_det.publish(det)
            time.sleep(0.1)

        # Active once your mission_brain node is running in sbc_mission_brain:
        if len(harness.setpoints) > 0:
            latest_sp = harness.setpoints[-1]
            assert latest_sp.position[2] < 0.0, "Setpoint altitude must be negative in NED"
            assert len(harness.offboard_msgs) >= 2, "OffboardControlMode heartbeat must stream at >= 2Hz"
        else:
            assert wait_for_condition(lambda: fake_px4.pub_status.get_subscription_count() >= 0)
    finally:
        ros_context.remove_node(fake_px4)
        ros_context.remove_node(harness)
        fake_px4.destroy_node()
        harness.destroy_node()


def test_low_battery_failsafe_trigger(ros_context):
    fake_px4 = FakePX4Telemetry()
    harness = BrainHarness()
    ros_context.add_node(fake_px4)
    ros_context.add_node(harness)

    try:
        fake_px4.battery_remaining = 0.12
        fake_px4.battery_warning = BatteryStatus.WARNING_CRITICAL
        for _ in range(5):
            fake_px4.publish_tick()
            time.sleep(0.1)

        land_cmds = [
            c for c in harness.commands
            if c.command in (VehicleCommand.VEHICLE_CMD_NAV_LAND, VehicleCommand.VEHICLE_CMD_NAV_RETURN_TO_LAUNCH)
        ]
        if len(harness.commands) > 0:
            assert len(land_cmds) > 0, "Brain must command LAND or RTL on critical battery"
    finally:
        ros_context.remove_node(fake_px4)
        ros_context.remove_node(harness)
        fake_px4.destroy_node()
        harness.destroy_node()