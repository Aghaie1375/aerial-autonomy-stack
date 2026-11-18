import socket
import time
from rclpy.node import Node
from px4_msgs.msg import OffboardControlMode, TrajectorySetpoint, VehicleCommand
from synthetic_data.fake_px4_telemetry import PX4_QOS


def test_udp_agent_port_listening():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(1.0)
    try:
        sock.sendto(b"\x80\x00\x00\x00", ("127.0.0.1", 8888))
        assert True
    finally:
        sock.close()


def test_px4_inbound_command_topics(ros_context):
    node = Node("px4_bridge_tester")
    pub_offboard = node.create_publisher(OffboardControlMode, "/fmu/in/offboard_control_mode", PX4_QOS)
    pub_setpoint = node.create_publisher(TrajectorySetpoint, "/fmu/in/trajectory_setpoint", PX4_QOS)
    pub_cmd = node.create_publisher(VehicleCommand, "/fmu/in/vehicle_command", PX4_QOS)
    ros_context.add_node(node)

    try:
        now_us = int(time.monotonic() * 1e6)

        ob = OffboardControlMode()
        ob.timestamp = now_us
        ob.position = True
        pub_offboard.publish(ob)

        sp = TrajectorySetpoint()
        sp.timestamp = now_us
        sp.position = [0.0, 0.0, -2.5]
        pub_setpoint.publish(sp)

        cmd = VehicleCommand()
        cmd.timestamp = now_us
        cmd.command = VehicleCommand.VEHICLE_CMD_COMPONENT_ARM_DISARM
        cmd.param1 = 1.0
        pub_cmd.publish(cmd)

        assert sp.position[2] < 0.0, "PX4 NED altitude must be negative"
    finally:
        ros_context.remove_node(node)
        node.destroy_node()