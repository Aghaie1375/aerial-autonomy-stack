import math
import time
from rclpy.node import Node
from std_msgs.msg import String
from px4_msgs.msg import TrajectorySetpoint
from synthetic_data.fake_px4_telemetry import FakePX4Telemetry, PX4_QOS


class ClosedLoopPlant(Node):
    def __init__(self, fake_px4: FakePX4Telemetry):
        super().__init__("closed_loop_plant")
        self.fake_px4 = fake_px4
        self.latest_sp = None
        self.pub_det = self.create_publisher(String, "/detections", 10)
        self.create_subscription(
            TrajectorySetpoint,
            "/fmu/in/trajectory_setpoint",
            self._on_setpoint,
            PX4_QOS,
        )

    def _on_setpoint(self, msg: TrajectorySetpoint):
        self.latest_sp = msg

    def step_physics(self, dt: float = 0.1, max_speed: float = 2.0):
        if self.latest_sp is None:
            return
        for i in range(3):
            target = float(self.latest_sp.position[i])
            if math.isnan(target):
                continue
            error = target - self.fake_px4.position[i]
            step = max(-max_speed * dt, min(max_speed * dt, error))
            self.fake_px4.position[i] += step
            self.fake_px4.velocity[i] = step / dt


def test_closed_loop_waypoint_convergence(ros_context):
    fake_px4 = FakePX4Telemetry()
    fake_px4.position = [0.0, 0.0, -2.0]
    plant = ClosedLoopPlant(fake_px4)
    ros_context.add_node(fake_px4)
    ros_context.add_node(plant)

    try:
        for _ in range(30):
            fake_px4.publish_tick()
            det = String()
            det.data = "target_detected:x=4.0,y=0.0"
            plant.pub_det.publish(det)
            plant.step_physics(dt=0.1, max_speed=2.0)
            time.sleep(0.1)

        if plant.latest_sp is not None:
            dx = plant.latest_sp.position[0] - fake_px4.position[0]
            dy = plant.latest_sp.position[1] - fake_px4.position[1]
            dz = plant.latest_sp.position[2] - fake_px4.position[2]
            dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            assert dist < 0.25, f"Drone failed to converge on setpoint (remaining distance: {dist:.2f}m)"
    finally:
        ros_context.remove_node(fake_px4)
        ros_context.remove_node(plant)
        fake_px4.destroy_node()
        plant.destroy_node()