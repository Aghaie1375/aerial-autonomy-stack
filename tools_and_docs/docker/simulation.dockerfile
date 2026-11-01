################################################################################
# Import ROS2 layer from aircraft.dockerfile, GCS layer from ground.dockerfile #
################################################################################
FROM transitional-ros2-gcs-image AS ros2-gcs-image

################################################################################
# Add Gazebo Sim ###############################################################
################################################################################
FROM ros2-gcs-image AS ros2-gcs-gz-image

# Gazebo Harmonic + Mesa AMD DRI/Vulkan drivers
# Based on https://gazebosim.org/docs/harmonic/install_ubuntu/
RUN apt update \
    && apt install -y --no-install-recommends \
    lsb-release gnupg \
    mesa-utils mesa-vulkan-drivers libgl1-mesa-dri \
    && curl https://packages.osrfoundation.org/gazebo.gpg --output /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] http://packages.osrfoundation.org/gazebo/ubuntu-stable $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/gazebo-stable.list > /dev/null \
    && apt update \
    && apt install -y --no-install-recommends \
    gz-harmonic ros-jazzy-ros-gz-bridge \
    libgz-transport13-* libgz-msgs10-dev \
    python3-gz-transport13 python3-gz-msgs10 \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*
ENV GZ_CONFIG_PATH=/usr/share/gz

################################################################################
# Add PX4 ######################################################################
################################################################################
FROM ros2-gcs-gz-image AS ros2-gcs-gz-px4-image

COPY /_github_clones/PX4-Autopilot /aas/github_apps/PX4-Autopilot
WORKDIR /aas/github_apps/PX4-Autopilot
RUN echo "numpy<2.0.0" > /etc/pip_constraints.txt \
    && PIP_CONSTRAINT=/etc/pip_constraints.txt bash ./Tools/setup/ubuntu.sh --no-sim-tools \
    && rm -rf /opt/xtensa-esp-elf Tools/setup/xtensa-esp-elf-*.tar.xz \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

################################################################################
# Add ArduPilot ################################################################
################################################################################
FROM ros2-gcs-gz-px4-image AS ros2-gcs-gz-px4-ardupilot-image

COPY /_github_clones/ardupilot /aas/github_apps/ardupilot
WORKDIR /aas/github_apps/ardupilot
RUN useradd -m -s /bin/bash arduuser \
    && echo "arduuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/arduuser && chmod 0440 /etc/sudoers.d/arduuser \
    && USER=arduuser SKIP_AP_GIT_CHECK=1 PIP_ONLY_BINARY=wxpython gosu arduuser bash ./Tools/environment_install/install-prereqs-ubuntu.sh -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
RUN ./waf configure --board sitl && ./waf copter plane
RUN ln -s /home/arduuser/venv-ardupilot/bin/mavproxy.py /usr/local/bin/mavproxy.py

COPY /_github_clones/ardupilot_gazebo /aas/github_apps/ardupilot_gazebo
COPY simulation/simulation_resources/patches/ardupilot_gazebo-imu-lockstep.patch /aas/github_apps/ardupilot_gazebo-imu-lockstep.patch
WORKDIR /aas/github_apps/ardupilot_gazebo
RUN apt update \
    && apt install -y --no-install-recommends \
    rapidjson-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*
ENV GZ_VERSION=harmonic
RUN git apply ../ardupilot_gazebo-imu-lockstep.patch && mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make -j$(nproc)

################################################################################
# Add GStreamer, wave simulation, ZeroMQ #######################################
################################################################################
FROM ros2-gcs-gz-px4-ardupilot-image AS ros2-gcs-gz-px4-ardupilot-gst-waves-zmq-image

RUN apt update \
    && apt install -y --no-install-recommends \
    gstreamer1.0-tools gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \ 
    gstreamer1.0-libav gstreamer1.0-gl \
    python3-gi gir1.2-gst-plugins-base-1.0 gir1.2-gstreamer-1.0 \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && \
    apt-get install -y --no-install-recommends libcgal-dev libfftw3-dev \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*
COPY /_github_clones/asv_wave_sim /aas/github_ws/src/asv_wave_sim
RUN sed -i 's|>materials/|>models://waves/materials/|g' /aas/github_ws/src/asv_wave_sim/gz-waves-models/world_models/waves/model.sdf
WORKDIR /aas/github_ws
RUN bash -c "source /opt/ros/jazzy/setup.bash && colcon build --symlink-install \
    --merge-install --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_TESTING=OFF -DCMAKE_CXX_STANDARD=17"
WORKDIR /aas/github_ws/src/asv_wave_sim/gz-waves/src/gui/plugins/waves_control
RUN mkdir build && cd build && cmake .. && make

RUN apt-get update && \
    apt-get install -y --no-install-recommends libzmq3-dev \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir --retries 5 pyzmq

################################################################################
# Add Betaflight with Gazebo SITL Plugin #######################################
################################################################################
FROM ros2-gcs-gz-px4-ardupilot-gst-waves-zmq-image AS ros2-gcs-gz-px4-ardupilot-gst-waves-zmq-betaflight-image

COPY /_github_clones/betaflight /aas/github_apps/betaflight
COPY simulation/simulation_resources/patches/betaflight-2026.6.2.patch /aas/github_apps/betaflight-2026.6.2.patch
WORKDIR /aas/github_apps/betaflight
RUN git apply ../betaflight-2026.6.2.patch && make TARGET=SITL
COPY /_github_clones/aeroloop_gazebo /aas/github_apps/aeroloop_gazebo
COPY simulation/simulation_resources/patches/aeroloop_gazebo-gz.patch /aas/github_apps/aeroloop_gazebo-gz.patch
WORKDIR /aas/github_apps/aeroloop_gazebo
RUN git apply ../aeroloop_gazebo-gz.patch && mkdir plugins/build && cd plugins/build && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j$(nproc)

################################################################################
# Ephemeral stage to grab AAS PX4 custom airframes #############################
################################################################################
FROM ubuntu:24.04 AS airframe_filter_stage
COPY simulation/simulation_resources/aircraft_models/ /temp_folder
RUN mkdir /airframes
RUN find /temp_folder -type f -regex '.*/[0-9]+_.*' -exec cp {} /airframes/ \;

################################################################################
# Build PX4 SITL with AAS airframes using the airframe_filter_stage stage ######
################################################################################
FROM ros2-gcs-gz-px4-ardupilot-gst-waves-zmq-betaflight-image AS ros2-gcs-gz-px4custom-ardupilot-gst-waves-zmq-betaflight-image

COPY simulation/simulation_resources/patches/px4-v1.17.0.patch /aas/github_apps/px4-v1.17.0.patch
WORKDIR /aas/github_apps/PX4-Autopilot
RUN git apply ../px4-v1.17.0.patch

COPY simulation/simulation_resources/patches/dds_topics.yaml /aas/github_apps/PX4-Autopilot/src/modules/uxrce_dds_client/dds_topics.yaml

COPY --from=airframe_filter_stage /airframes/ /aas/github_apps/PX4-Autopilot/ROMFS/px4fmu_common/init.d-posix/airframes/
WORKDIR /aas/github_apps/PX4-Autopilot/ROMFS/px4fmu_common/init.d-posix/airframes
RUN rm -f CMakeLists.txt && \
    echo "px4_add_romfs_files(" >> CMakeLists.txt && \
    find ./ -type f -printf '%f\n' | sed 's/^/  /' >> CMakeLists.txt && \
    echo ")" >> CMakeLists.txt

WORKDIR /aas/github_apps/PX4-Autopilot
RUN make px4_sitl

################################################################################
# Copy AAS resources and build AAS ROS2 workspace ##############################
################################################################################
FROM ros2-gcs-gz-px4custom-ardupilot-gst-waves-zmq-betaflight-image AS simulation-manifests

COPY simulation/simulation_ws/src /src
RUN find /src -type f ! -name package.xml -delete

FROM ros2-gcs-gz-px4custom-ardupilot-gst-waves-zmq-betaflight-image AS simulation-dev-image

COPY --from=simulation-manifests /src /aas/simulation_ws/src
WORKDIR /aas/simulation_ws
RUN rosdep update
RUN apt update && rosdep install --from-paths src/ --ignore-src --rosdistro jazzy -y && apt clean && rm -rf /var/lib/apt/lists/*

COPY simulation/simulation_ws/src /aas/simulation_ws/src
RUN bash -c "source /opt/ros/jazzy/setup.bash && (source /aas/github_ws/install/setup.bash || true) && colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release"

COPY simulation/simulation_resources/ /aas/simulation_resources
RUN chmod +x /aas/simulation_resources/patches/create_*_drones_and_world.sh

COPY ground/ground_resources/patches/QGroundControl.ini /home/qgcuser/.config/QGroundControl/QGroundControl.ini
COPY ground/ground_resources/scripts/betaflight_app.py /aas/ground_resources/scripts/betaflight_app.py

WORKDIR /aas/simulation_resources/comms/gz_gst_bridge
RUN mkdir build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && make

RUN echo "source /aas/github_ws/install/local_setup.bash" >> /root/.bashrc \
    && echo "source /aas/simulation_ws/install/local_setup.bash" >> /root/.bashrc

WORKDIR /aas
COPY simulation/simulation.yml.erb /aas/simulation.yml.erb
COPY simulation/simulation_resources/patches/tmux.conf /root/.tmux.conf
ENTRYPOINT ["tmuxinator", "start", "-p", "/aas/simulation.yml.erb"]