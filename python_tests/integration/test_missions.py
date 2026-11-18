import math
import statistics
import time
from dataclasses import dataclass, field
from rclpy.node import Node
from std_msgs.msg import String
from px4_msgs.msg import OffboardControlMode, TrajectorySetpoint, VehicleCommand, BatteryStatus
from conftest import wait_for_condition
from synthetic_data.fake_px4_telemetry import FakePX4Telemetry, PX4_QOS


@dataclass
class FlightMetrics:
    heartbeat_timestamps: list = field(default_factory=list)
    setpoint_timestamps: list = field(default_factory=list)
    tracking_errors: list = field(default_factory=list)
    commands_received: list = field(default_factory=list)
    failsafe_latency_ms: float = -1.0

    def heartbeat_hz(self) -> float:
        if len(self.heartbeat_timestamps) < 2:
            return 0.0
        duration = self.heartbeat_timestamps[-1] - self.heartbeat_timestamps[0]
        return (len(self.heartbeat_timestamps) - 1) / duration if duration > 0 else 0.0

    def setpoint_jitter_ms(self) -> float:
        if len(self.setpoint_timestamps) < 3:
            return 0.0
        intervals = [
            (self.setpoint_timestamps[i] - self.setpoint_timestamps[i - 1]) * 1000.0
            for i in range(1, len(self.setpoint_timestamps))
        ]
        return statistics.stdev(intervals)

    def tracking_rmse(self) -> float:
        if not self.tracking_errors:
            return float("inf")
        return math.sqrt(sum(e * e for e in self.tracking_errors) / len(self.tracking_errors))


class MissionTestBench(Node):
    def __init__(self, fake_px4: FakePX4Telemetry):
        super().__init__("mission_test_bench")
        self.fake_px4 = fake_px4
        self.metrics = FlightMetrics()
        self.latest_sp = None
        self.warning_injected_at = None

        self.pub_det = self.create_publisher(String, "/detections", 10)
        self.create_subscription(OffboardControlMode, "/fmu/in/offboard_control_mode", self._on_hb, PX4_QOS)
        self.create_subscription(TrajectorySetpoint, "/fmu/in/trajectory_setpoint", self._on_sp, PX4_QOS)
        self.create_subscription(VehicleCommand, "/fmu/in/vehicle_command", self._on_cmd, PX4_QOS)

    def _on_hb(self, _msg):
        self.metrics.heartbeat_timestamps.append(time.monotonic())

    def _on_sp(self, msg: TrajectorySetpoint):
        self.metrics.setpoint_timestamps.append(time.monotonic())
        self.latest_sp = msg

    def _on_cmd(self, msg: VehicleCommand):
        self.metrics.commands_received.append(msg)
        if self.warning_injected_at is not None and self.metrics.failsafe_latency_ms < 0:
            self.metrics.failsafe_latency_ms = (time.monotonic() - self.warning_injected_at) * 1000.0

    def step_dynamics(self, target_xy, dt: float = 0.1, max_speed: float = 2.5):
        if self.latest_sp is not None:
            for i in range(3):
                goal = float(self.latest_sp.position[i])
                if not math.isnan(goal):
                    err = goal - self.fake_px4.position[i]
                    step = max(-max_speed * dt, min(max_speed * dt, err))
                    self.fake_px4.position[i] += step
                    self.fake_px4.velocity[i] = step / dt

        # Record 2D tracking error against moving target
        dx = target_xy[0] - self.fake_px4.position[0]
        dy = target_xy[1] - self.fake_px4.position[1]
        self.metrics.tracking_errors.append(math.hypot(dx, dy))


def test_moving_target_follow_and_failsafe(ros_context):
    fake_px4 = FakePX4Telemetry()
    fake_px4.position = [0.0, 0.0, -2.0]
    bench = MissionTestBench(fake_px4)
    ros_context.add_node(fake_px4)
    ros_context.add_node(bench)

    try:
        assert wait_for_condition(lambda: bench.pub_det.get_subscription_count() > 0, timeout_sec=3.0), \
            "mission_brain_node must be running before executing mission tests"

        # Phase 1: Chase a target moving East at 1.0 m/s for 4.0 seconds
        target_x, target_y = 2.0, 0.0
        for _ in range(40):
            target_y += 0.1  # 1.0 m/s at 10 Hz
            fake_px4.publish_tick()

            det = String()
            det.data = f"target_detected:x={target_x:.2f},y={target_y:.2f}"
            bench.pub_det.publish(det)

            bench.step_dynamics((target_x, target_y), dt=0.1, max_speed=2.5)
            time.sleep(0.1)

        # Evaluate Phase 1 Success & Performance
        final_error = bench.metrics.tracking_errors[-1]
        rmse = bench.metrics.tracking_rmse()
        hb_hz = bench.metrics.heartbeat_hz()
        jitter = bench.metrics.setpoint_jitter_ms()

        print(f"\n[Metrics] Final Error: {final_error:.2f}m | RMSE: {rmse:.2f}m | HB: {hb_hz:.1f}Hz | Jitter: {jitter:.2f}ms")

        # Hard Success/Failure Gates
        assert hb_hz >= 2.0, f"FAIL: Offboard heartbeat too slow ({hb_hz:.1f} Hz < 2.0 Hz)"
        assert bench.latest_sp.position[2] < 0.0, "FAIL: Commanded underground NED altitude"
        assert final_error < 0.5, f"FAIL: Drone failed to intercept moving target (error: {final_error:.2f}m)"

        # Phase 2: Inject Critical Battery Failsafe
        bench.warning_injected_at = time.monotonic()
        fake_px4.battery_remaining = 0.10
        fake_px4.battery_warning = BatteryStatus.WARNING_CRITICAL

        for _ in range(5):
            fake_px4.publish_tick()
            time.sleep(0.1)

        land_cmds = [
            c for c in bench.metrics.commands_received
            if c.command in (VehicleCommand.VEHICLE_CMD_NAV_LAND, VehicleCommand.VEHICLE_CMD_NAV_RETURN_TO_LAUNCH)
        ]
        print(f"[Metrics] Failsafe Reaction Latency: {bench.metrics.failsafe_latency_ms:.1f}ms")

        assert len(land_cmds) > 0, "FAIL: Brain did not trigger NAV_LAND or RTL on critical battery"
        assert 0.0 <= bench.metrics.failsafe_latency_ms < 500.0, "FAIL: Failsafe reaction exceeded 500ms"

    finally:
        ros_context.remove_node(fake_px4)
        ros_context.remove_node(bench)
        fake_px4.destroy_node()
        bench.destroy_node()