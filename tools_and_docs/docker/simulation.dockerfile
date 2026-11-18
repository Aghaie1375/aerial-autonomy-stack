################################################################################
# Ephemeral Stage: Extract Author's Custom PX4 Airframes                       #
################################################################################
FROM ubuntu:24.04 AS airframe_filter_stage
COPY simulation/simulation_resources/aircraft_models/ /temp_folder
RUN mkdir /airframes && \
    find /temp_folder -type f -regex '.*/[0-9]+_.*' -exec cp {} /airframes/ \;

################################################################################
# Stage 1: Base ROS 2 Jazzy + Missing ros2-image/gcs-image Tools + AMD GPU     #
################################################################################
FROM osrf/ros:jazzy-desktop-full AS ros2-gz-amd-base

# Environment variables inherited from aircraft.dockerfile (ros2-image)
ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_NO_CACHE_DIR=1
ENV CCACHE_DISABLE=1
ENV LANG=en_US.UTF-8

# Environment variables for Gazebo Harmonic, AMD RX 7900 XTX & WSL ssh -Y
ENV QT_X11_NO_MITSHM=1
ENV XAUTHORITY=/tmp/.Xauthority
ENV GZ_SIM_RESOURCE_PATH=/workspace/models:/aas/simulation_resources
ENV GZ_CONFIG_PATH=/usr/share/gz
ENV MESA_LOADER_DRIVER_OVERRIDE=radeonsi
ENV VGL_COMPRESS=proxy
ENV GZ_IP=127.0.0.1

# 1. Configure UTF-8 locales (from aircraft.dockerfile)
RUN apt-get update && apt-get install -y --no-install-recommends locales \
    && locale-gen en_US en_US.UTF-8 \
    && update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# 2. Install base tools from aircraft/ground dockerfiles + AMD Mesa/EGL/Vulkan + X11
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git sudo gosu ca-certificates lsb-release gnupg software-properties-common \
    ruby tmux xclip net-tools iproute2 iputils-ping netcat-openbsd socat \
    python3-pip python3-venv python3-rosdep \
    ros-dev-tools ros-jazzy-bondcpp ros-jazzy-ament-cmake-clang-format ros-jazzy-vision-msgs \
    mesa-utils mesa-vulkan-drivers libgl1-mesa-dri libglx-mesa0 libegl1 libegl-mesa0 libgbm1 \
    x11-apps xauth \
    && gem install tmuxinator \
    && (rosdep init || true) \
    && useradd -m -s /bin/bash -u 1000 -o qgcuser || true \
    && rm -rf /var/lib/apt/lists/*

# 3. Install Zenoh ROS 2 bridge (from aircraft.dockerfile, needed to bridge with aircraft container)
RUN curl -fsSL https://download.eclipse.org/zenoh/debian-repo/zenoh-public-key | gpg --dearmor --yes --output /etc/apt/keyrings/zenoh-public-key.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/zenoh-public-key.gpg] https://download.eclipse.org/zenoh/debian-repo/ /" > /etc/apt/sources.list.d/zenoh.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends zenoh-bridge-ros2dds \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 4. Add OSRF Gazebo repository and install Gazebo Harmonic + ROS 2 bindings
RUN curl -fsSL https://packages.osrfoundation.org/gazebo.gpg -o /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] http://packages.osrfoundation.org/gazebo/ubuntu-stable $(lsb_release -cs) main" > /etc/apt/sources.list.d/gazebo-stable.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    gz-harmonic \
    ros-jazzy-ros-gz-bridge \
    libgz-transport13-* \
    libgz-msgs10-dev \
    python3-gz-transport13 \
    python3-gz-msgs10 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 5. Install VirtualGL for AMD GPU rendering over WSL ssh -Y
RUN VGL_VER=3.1.5 && \
    wget -q "https://github.com/VirtualGL/virtualgl/releases/download/${VGL_VER}/virtualgl_${VGL_VER}_amd64.deb" -O /tmp/virtualgl.deb && \
    apt-get update && apt-get install -y --no-install-recommends /tmp/virtualgl.deb && \
    rm -f /tmp/virtualgl.deb && \
    rm -rf /var/lib/apt/lists/*

################################################################################
# Stage 2: PX4-Autopilot + Author's Patches, DDS Topics & Custom Airframes     #
################################################################################
FROM ros2-gz-amd-base AS ros2-gz-amd-px4

# 1. Copy the author's local PX4-Autopilot clone to the exact expected path
COPY /_github_clones/PX4-Autopilot /aas/github_apps/PX4-Autopilot
WORKDIR /aas/github_apps/PX4-Autopilot

# 2. Install PX4 build tools while constraining numpy<2.0.0 for Ubuntu 24.04 compatibility
RUN echo "numpy<2.0.0" > /etc/pip_constraints.txt \
    && PIP_CONSTRAINT=/etc/pip_constraints.txt bash ./Tools/setup/ubuntu.sh --no-sim-tools \
    && rm -rf /opt/xtensa-esp-elf Tools/setup/xtensa-esp-elf-*.tar.xz \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 3. Apply the author's PX4 v1.17.0 patch and uXRCE-DDS topic configuration
COPY simulation/simulation_resources/patches/px4-v1.17.0.patch /aas/github_apps/px4-v1.17.0.patch
RUN git apply ../px4-v1.17.0.patch

COPY simulation/simulation_resources/patches/dds_topics.yaml /aas/github_apps/PX4-Autopilot/src/modules/uxrce_dds_client/dds_topics.yaml

# 4. Inject the author's custom airframes into PX4 ROMFS and regenerate CMakeLists.txt
COPY --from=airframe_filter_stage /airframes/ /aas/github_apps/PX4-Autopilot/ROMFS/px4fmu_common/init.d-posix/airframes/
WORKDIR /aas/github_apps/PX4-Autopilot/ROMFS/px4fmu_common/init.d-posix/airframes
RUN rm -f CMakeLists.txt && \
    echo "px4_add_romfs_files(" >> CMakeLists.txt && \
    find ./ -type f -printf '%f\n' | sed 's/^/  /' >> CMakeLists.txt && \
    echo ")" >> CMakeLists.txt

# 5. Compile PX4 SITL with the author's control modifications baked in
WORKDIR /aas/github_apps/PX4-Autopilot
RUN make px4_sitl

################################################################################
# Stage 3: GStreamer (for gz_gst_bridge & drone cameras) + ZeroMQ Messaging    #
################################################################################
FROM ros2-gz-amd-px4 AS ros2-gz-amd-px4-gst-zmq

# 1. Install GStreamer libraries (required by gz_gst_bridge and drone camera plugins)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-gl \
    python3-gi \
    gir1.2-gst-plugins-base-1.0 \
    gir1.2-gstreamer-1.0 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 2. Create empty github_ws placeholder scripts (asv_wave_sim ocean physics intentionally omitted)
RUN mkdir -p /aas/github_ws/install && \
    touch /aas/github_ws/install/setup.bash /aas/github_ws/install/local_setup.bash

# 3. Install ZeroMQ C++ and Python libraries for control/orchestration scripts
RUN apt-get update \
    && apt-get install -y --no-install-recommends libzmq3-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && PIP_CONSTRAINT=/etc/pip_constraints.txt pip3 install --no-cache-dir --retries 5 pyzmq

################################################################################
# Stage 4: Author's ROS 2 Control Workspace, Resources & AMD/X11 Entrypoint     #
################################################################################
FROM ros2-gz-amd-px4-gst-zmq AS simulation-manifests

# Keep only package.xml files so rosdep caches dependencies cleanly
COPY simulation/simulation_ws/src /src
RUN find /src -type f ! -name package.xml -delete

FROM ros2-gz-amd-px4-gst-zmq AS simulation-dev-image

# 1. Install ROS 2 workspace dependencies
COPY --from=simulation-manifests /src /aas/simulation_ws/src
WORKDIR /aas/simulation_ws
RUN sed -i "/osx-homebrew/d" /etc/ros/rosdep/sources.list.d/20-default.list && (rosdep update --rosdistro jazzy || rosdep update --rosdistro jazzy) \
    && apt-get update \
    && rosdep install --from-paths src/ --ignore-src --rosdistro jazzy -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 2. Build the author's ROS 2 control workspace
COPY simulation/simulation_ws/src /aas/simulation_ws/src
RUN bash -c "source /opt/ros/jazzy/setup.bash && source /aas/github_ws/install/setup.bash && colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release"

# 3. Copy world/drone creator scripts, resources, and ground configs
COPY simulation/simulation_resources/ /aas/simulation_resources
RUN chmod +x /aas/simulation_resources/patches/create_*_drones_and_world.sh

RUN mkdir -p /home/qgcuser/.config/QGroundControl /aas/ground_resources/scripts
COPY ground/ground_resources/patches/QGroundControl.ini /home/qgcuser/.config/QGroundControl/QGroundControl.ini
COPY ground/ground_resources/scripts/betaflight_app.py /aas/ground_resources/scripts/betaflight_app.py

# 4. Build gz_gst_bridge
WORKDIR /aas/simulation_resources/comms/gz_gst_bridge
RUN mkdir -p build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && make -j$(nproc)

# 5. Auto-route GUI 'gz sim' calls through VirtualGL on the AMD GPU for tmuxinator & docker exec
RUN printf '#!/usr/bin/env bash\nsource /opt/ros/jazzy/setup.bash\nif [[ "$1" == "sim" && "$*" != *" -s"* && "$*" != *"--headless-rendering"* && -n "$DISPLAY" ]]; then\n  exec vglrun /usr/bin/gz "$@"\nelse\n  exec /usr/bin/gz "$@"\nfi\n' > /usr/local/bin/gz && \
    chmod +x /usr/local/bin/gz

# 6. Source ROS 2 and AAS workspaces in interactive shells
RUN echo "source /opt/ros/jazzy/setup.bash" >> /root/.bashrc \
    && echo "source /aas/github_ws/install/local_setup.bash" >> /root/.bashrc \
    && echo "source /aas/simulation_ws/install/local_setup.bash" >> /root/.bashrc

# 7. Copy AMD GPU / X11 SSH entrypoint & tmuxinator configuration
# 5. Auto-route GUI 'gz sim' calls through VirtualGL on the AMD GPU for tmuxinator & docker exec
RUN printf '#!/usr/bin/env bash\nsource /opt/ros/jazzy/setup.bash\nif [[ "$1" == "sim" && "$*" != *" -s"* && "$*" != *"--headless-rendering"* && -n "$DISPLAY" ]]; then\n  exec vglrun /usr/bin/gz "$@"\nelse\n  exec /usr/bin/gz "$@"\nfi\n' > /usr/local/bin/gz && \
    chmod +x /usr/local/bin/gz

# 6. Source ROS 2 and AAS workspaces in interactive shells
RUN echo "source /opt/ros/jazzy/setup.bash" >> /root/.bashrc \
    && echo "source /aas/github_ws/install/local_setup.bash" >> /root/.bashrc \
    && echo "source /aas/simulation_ws/install/local_setup.bash" >> /root/.bashrc

# 7. Generate AMD GPU / X11 SSH entrypoint & tmuxinator configuration
RUN printf '#!/usr/bin/env bash\nset -e\nif [ -f /root/.Xauthority.ro ]; then\n    cp /root/.Xauthority.ro /tmp/.Xauthority\n    chmod 644 /tmp/.Xauthority\nfi\nexport XAUTHORITY=/tmp/.Xauthority\nsource /opt/ros/jazzy/setup.bash\n[ -f /aas/github_ws/install/local_setup.bash ] && source /aas/github_ws/install/local_setup.bash\n[ -f /aas/simulation_ws/install/local_setup.bash ] && source /aas/simulation_ws/install/local_setup.bash\nexec "$@"\n' > /entrypoint.sh \
    && chmod +x /entrypoint.sh

WORKDIR /aas
COPY simulation/simulation.yml.erb /aas/simulation.yml.erb
COPY simulation/simulation_resources/patches/tmux.conf /root/.tmux.conf

ENTRYPOINT ["/entrypoint.sh", "tmuxinator", "start", "-p", "/aas/simulation.yml.erb"]