import threading
import time
import pytest
import rclpy
from rclpy.executors import MultiThreadedExecutor


@pytest.fixture(scope="session", autouse=True)
def ros_context():
    rclpy.init()
    executor = MultiThreadedExecutor()
    spin_thread = threading.Thread(target=executor.spin, daemon=True)
    spin_thread.start()
    yield executor
    executor.shutdown()
    rclpy.shutdown()


def wait_for_condition(predicate, timeout_sec: float = 5.0, poll_sec: float = 0.05) -> bool:
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(poll_sec)
    return False