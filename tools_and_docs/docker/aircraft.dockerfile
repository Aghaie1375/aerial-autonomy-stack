# Use an ARG to selectively build or skip the advanced odometry, SLAM packages
ARG BUILD_ADVANCED_ODOM=true
ARG TARGETARCH=amd64

################################################################################
# Base Ubuntu 24.04 image for AMD GPU simulation host ##########################
################################################################################
FROM ubuntu:24.04 AS base_amd64

################################################################################
# Add tools, AMD GPU / VirtualGL display stack, and ROS2 #######################
################################################################################
FROM base_${TARGETARCH} AS ros2-image

# Tell apt (and other Debian tools) not to prompt for user input during package installs
ENV DEBIAN_FRONTEND=noninteractive

# Ubuntu 24 blocks system-wide pip installs by default, --break-system-packages allows global pip installs
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# Keep pip's download cache out of the image layers
ENV PIP_NO_CACHE_DIR=1

# Keep ccache out of the image layers
ENV CCACHE_DISABLE=1

# Pre-configure Qt, writable X11 cookie path, and VirtualGL EGL proxy over ssh -Y
ENV QT_X11_NO_MITSHM=1
ENV XAUTHORITY=/tmp/.Xauthority
ENV VGL_DISPLAY=egl
ENV VGL_COMPRESS=proxy

# Install general use tools, AMD Mesa/EGL/Vulkan drivers, and X11 utilities
RUN apt update \
    && apt install -y --no-install-recommends \
    wget ca-certificates gosu htop vim ruby tmux xclip \
    net-tools iproute2 iputils-ping netcat-openbsd \
    python3-pip python3-venv \
    libgl1-mesa-dri libglx-mesa0 libegl1 libegl-mesa0 \
    libgbm1 mesa-vulkan-drivers mesa-utils x11-apps xauth \
    && gem install tmuxinator \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

# Install VirtualGL so the Ubuntu Server's AMD RX 7900 XTX renders 3D GUIs over ssh -Y
RUN VGL_VER=3.1.5 && \
    wget -q "https://github.com/VirtualGL/virtualgl/releases/download/${VGL_VER}/virtualgl_${VGL_VER}_amd64.deb" -O /tmp/virtualgl.deb && \
    apt-get update && apt-get install -y --no-install-recommends /tmp/virtualgl.deb && \
    rm -f /tmp/virtualgl.deb && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install ROS2 Jazzy
# Based on https://docs.ros.org/en/jazzy/Installation/Ubuntu-Install-Debs.html
ENV LANG=en_US.UTF-8
RUN apt update \
    && apt install -y --no-install-recommends \
    locales \
    && locale-gen en_US en_US.UTF-8 \
    && update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 \
    && apt install -y --no-install-recommends \
    software-properties-common curl gpg \
    && curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu \
    $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null \
    && apt update \
    && apt install -y --no-install-recommends \
    ros-jazzy-desktop ros-dev-tools \
    ros-jazzy-bondcpp ros-jazzy-ament-cmake-clang-format \
    ros-jazzy-vision-msgs \
    && apt clean \
    && rm -rf /var/lib/apt/lists/* \
    && echo "source /opt/ros/jazzy/setup.bash" >> /root/.bashrc \
    && rosdep init

# 3. Install Zenoh ROS 2 bridge (matching aircraft.dockerfile)
RUN echo "deb [trusted=yes] https://download.eclipse.org/zenoh/debian-repo/ /" > /etc/apt/sources.list.d/zenoh.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends zenoh-bridge-ros2dds \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

################################################################################
# Add PX4 messages #############################################################
################################################################################
FROM ros2-image AS ros2-px4msgs-image

# Build PX4 messages
COPY /_github_clones/px4_msgs /aas/github_ws/src/px4_msgs
WORKDIR /aas/github_ws
RUN sed -i "/osx-homebrew/d" /etc/ros/rosdep/sources.list.d/20-default.list && (rosdep update --rosdistro jazzy || rosdep update --rosdistro jazzy)
RUN rosdep install --from-paths src --ignore-src --rosdistro jazzy -y && apt clean && rm -rf /var/lib/apt/lists/*
# Explicitly use bash, not sh, to source and build the workspace
RUN bash -c "source /opt/ros/jazzy/setup.bash && colcon build --symlink-install"

################################################################################
# Add uXRCE-DDS agent ##########################################################
################################################################################
FROM ros2-px4msgs-image AS ros2-px4msgs-dds-image

# XRCE-DDS
# Based on https://micro-xrce-dds.docs.eprosima.com/en/latest/installation.html#installing-the-agent-standalone
COPY /_github_clones/Micro-XRCE-DDS-Agent /aas/github_apps/Micro-XRCE-DDS-Agent
WORKDIR /aas/github_apps/Micro-XRCE-DDS-Agent
RUN mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make -j$(nproc) && \
    make install && \
    ldconfig
# Run with $ MicroXRCEAgent udp4 -p 8888

################################################################################
# Add MAVROS ###################################################################
################################################################################
FROM ros2-px4msgs-dds-image AS ros2-px4msgs-dds-mavros-image

# MAVROS
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ros-jazzy-mavros ros-jazzy-mavros-extras ros-jazzy-mavros-msgs \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*
# Re-try install_geographiclib_datasets.sh if egm96-5.pgm was not downloaded (timeout is ~10x the time needed on a healthy link)
RUN for i in 1 2 3; do \
    rm -f /usr/share/GeographicLib/geoids/egm96-5*; \
    timeout 180 /opt/ros/jazzy/lib/mavros/install_geographiclib_datasets.sh; \
    test -r /usr/share/GeographicLib/geoids/egm96-5.pgm && break; \
    sleep 5; \
    done && test -r /usr/share/GeographicLib/geoids/egm96-5.pgm
# Run with $ ros2 launch mavros apm.launch fcu_url:=[URI]

################################################################################
# Add GStreamer, OpenCV, and Ultralytics YOLO ##################################
################################################################################
FROM ros2-px4msgs-dds-mavros-image AS ros2-px4msgs-dds-mavros-yolo-image

# In Ubuntu 24, package python3-numpy is on version 1.26.4, check with $ dpkg -l | grep python3-numpy
# We constrain pip install to <2.0.0 for system Python's OpenCV ABI compatibility
# Check with $ python3 -c "import numpy; print(numpy.__version__)"
RUN echo "numpy<2.0.0" > /etc/pip_constraints.txt
ENV PIP_CONSTRAINT=/etc/pip_constraints.txt
# Point the GCC compiler to the new pip NumPy headers (instead of the apt ones) to prevent ROS2 colcon from crashing
ENV CPATH=/usr/local/lib/python3.12/dist-packages/numpy/core/include

# Add GStreamer (with X11/VA-API support) and Python OpenCV packages
RUN apt update \
    && apt install -y --no-install-recommends \
    gstreamer1.0-tools gstreamer1.0-x gstreamer1.0-vaapi \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
    mesa-va-drivers python3-opencv \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

# Install YOLO and ONNX in virtual environment /yolo-env/
# NOTE: the venv avoids shadowing system Python's OpenCV (with GStreamer support)
RUN python3 -m venv /yolo-env \
    && /yolo-env/bin/pip3 install --no-cache-dir --upgrade pip && \
    /yolo-env/bin/pip3 install --no-cache-dir --retries 5 \
    --extra-index-url https://download.pytorch.org/whl/cpu \
    ultralytics onnx
# Check YOLO with $ /yolo-env/bin/python3 -c "import ultralytics; print(ultralytics.__version__)"

################################################################################
# amd64 stage for ONNX Runtime (replaces NVIDIA CUDA onnxruntime-gpu) ###########
################################################################################
FROM ros2-px4msgs-dds-mavros-yolo-image AS image-with-hardware-specific-ort_amd64
# Use standard onnxruntime (CPUExecutionProvider) instead of CUDA-only onnxruntime-gpu
# (Respects PIP_CONSTRAINT=numpy<2.0.0 for OpenCV & ROS 2 ABI compatibility)
RUN pip3 install --no-cache-dir --retries 5 onnxruntime
# Check with $ python3 -c "import onnxruntime as ort; print(ort.__version__); print(ort.get_available_providers())"

################################################################################
# Add odometry packages ########################################################
################################################################################
FROM image-with-hardware-specific-ort_${TARGETARCH} AS ros2-px4msgs-dds-mavros-yolo-ort-simple-odom-image

# Install the Livox SDK (livox_ros_driver2 requirement)
COPY /_github_clones/Livox-SDK2 /aas/github_apps/Livox-SDK2
WORKDIR /aas/github_apps/Livox-SDK2
RUN mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# Install the Livox ROS2 driver (SuperOdom requirement) for, e.g., the Mid-360s, based on https://github.com/Livox-SDK/livox_ros_driver2/blob/master/README.md
# And https://github.com/Livox-SDK/livox_ros_driver2/blob/master/build.sh
COPY /_github_clones/livox_ros_driver2 /aas/github_ws/src/livox_ros_driver2
WORKDIR /aas/github_ws/
RUN cp -f src/livox_ros_driver2/package_ROS2.xml src/livox_ros_driver2/package.xml \
    && cp -rf src/livox_ros_driver2/launch_ROS2 src/livox_ros_driver2/launch
# Explicitly use bash, not sh, to source and build the workspace
RUN bash -c "source /opt/ros/jazzy/setup.bash && colcon build --symlink-install --packages-select livox_ros_driver2 --cmake-args -DROS_EDITION=ROS2 -DDISTRO_ROS=jazzy -DCMAKE_BUILD_TYPE=Release"

# Install KISS-ICP, based on https://github.com/PRBonn/kiss-icp/blob/main/README.md
COPY /_github_clones/kiss-icp /aas/github_ws/src/kiss-icp
WORKDIR /aas/github_ws
# Explicitly use bash, not sh, to source and build the workspace
RUN bash -c "source /opt/ros/jazzy/setup.bash && colcon build --symlink-install --packages-skip livox_ros_driver2 --cmake-args -DCMAKE_BUILD_TYPE=Release"

################################################################################
# Empty branch to skip the build of advanced odometry, SLAM packages ###########
# Mutually exclusive with the next stage #######################################
################################################################################
FROM ros2-px4msgs-dds-mavros-yolo-ort-simple-odom-image AS advanced-odom-false
# Do nothing


################################################################################
# Branch including the build of advanced odometry, SLAM packages ###############
# Mutually exclusive with the previous stage ###################################
################################################################################
FROM ros2-px4msgs-dds-mavros-yolo-ort-simple-odom-image AS advanced-odom-true

# Install OpenVINS, based on https://docs.openvins.com/gs-installing.html
RUN apt-get update && \
    apt-get install -y --no-install-recommends libeigen3-dev libboost-all-dev libceres-dev libopencv-contrib-dev \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*
COPY /_github_clones/open_vins /aas/github_ws/src/open_vins
# Fix ROS 2 Jazzy compatibility: these headers dropped the .h form for .hpp
RUN grep -rlZ -e 'image_transport/image_transport\.h>' -e 'cv_bridge/cv_bridge\.h>' \
    -e 'tf2_geometry_msgs/tf2_geometry_msgs\.h>' -e 'sensor_msgs/point_cloud2_iterator\.h>' \
    /aas/github_ws/src/open_vins \
    | xargs -0 sed -i -e 's|\(image_transport/image_transport\)\.h>|\1.hpp>|' \
    -e 's|\(cv_bridge/cv_bridge\)\.h>|\1.hpp>|' \
    -e 's|\(tf2_geometry_msgs/tf2_geometry_msgs\)\.h>|\1.hpp>|' \
    -e 's|\(sensor_msgs/point_cloud2_iterator\)\.h>|\1.hpp>|'
WORKDIR /aas/github_ws
# Explicitly use bash, not sh, to source and build the workspace
# Limiting resource usage to avoid freezes on resource-constrained hosts
RUN MAKEFLAGS='-j4' NINJAJOBS='-j4' bash -c "source /opt/ros/jazzy/setup.bash && colcon build --event-handlers console_cohesion+ --packages-select ov_core ov_init ov_msckf ov_eval --cmake-args -DCMAKE_BUILD_TYPE=Release"

# Install SPARK-FAST-LIO, based on https://github.com/MIT-SPARK/spark-fast-lio#package-how-to-install
COPY /_github_clones/spark-fast-lio /aas/github_ws/src/spark-fast-lio
WORKDIR /aas/github_ws
# Explicitly use bash, not sh, to source and build the workspace
RUN bash -c "source /opt/ros/jazzy/setup.bash && colcon build --packages-up-to spark_fast_lio --cmake-args -DCMAKE_BUILD_TYPE=Release"

# Install SuperOdom dependencies, based on https://github.com/superxslam/SuperOdom#-3-installation
# Sophus on 2021's commit https://github.com/strasdat/Sophus/commit/97e7161
WORKDIR /aas/github_apps/
RUN mkdir Sophus \
    && wget --tries=5 --retry-connrefused --retry-on-http-error=429,500,502,503,504 --waitretry=10 --timeout=30 -O /tmp/repo_archive.tar.gz https://github.com/strasdat/Sophus/archive/97e7161.tar.gz \
    && tar -xzf /tmp/repo_archive.tar.gz -C Sophus --strip-components=1 && rm /tmp/repo_archive.tar.gz \
    && cd Sophus \
    && mkdir build && cd build \
    && cmake .. -DBUILD_TESTS=OFF \
    && make -j$(nproc) \
    && make install
# gtsam on 2024's commit https://github.com/borglab/gtsam/commit/4abef92, also required by KISS-Matcher
WORKDIR /aas/github_apps/
RUN mkdir gtsam \
    && wget --tries=5 --retry-connrefused --retry-on-http-error=429,500,502,503,504 --waitretry=10 --timeout=30 -O /tmp/repo_archive.tar.gz https://github.com/borglab/gtsam/archive/4abef92.tar.gz \
    && tar -xzf /tmp/repo_archive.tar.gz -C gtsam --strip-components=1 && rm /tmp/repo_archive.tar.gz \
    && cd gtsam \
    && mkdir build && cd build \
    && cmake -DGTSAM_USE_SYSTEM_EIGEN=ON -DGTSAM_BUILD_WITH_MARCH_NATIVE=OFF -DGTSAM_BUILD_EXAMPLES_ALWAYS=OFF .. \
    && make -j$(nproc) \
    && make install
# f68321e tag is release 2.1.0 https://github.com/ceres-solver/ceres-solver/releases/tag/2.1.0
WORKDIR /aas/github_apps/
RUN apt-get update && \
    apt-get install -y --no-install-recommends libgoogle-glog-dev \
    && apt clean \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir ceres-solver \
    && wget --tries=5 --retry-connrefused --retry-on-http-error=429,500,502,503,504 --waitretry=10 --timeout=30 -O /tmp/repo_archive.tar.gz https://github.com/ceres-solver/ceres-solver/archive/f68321e.tar.gz \
    && tar -xzf /tmp/repo_archive.tar.gz -C ceres-solver --strip-components=1 && rm /tmp/repo_archive.tar.gz \
    && cd ceres-solver \
    && mkdir build && cd build \
    && cmake .. -DCXSPARSE=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
    && make -j$(nproc) \
    && make install
RUN pip3 install --no-cache-dir --retries 5 rerun-sdk
# Add rviz_2d_overlay_plugins, based on https://github.com/teamspatzenhirn/rviz_2d_overlay_plugins#rviz_2d_overlay_plugins
RUN mkdir -p /aas/github_ws/src/rviz_2d_overlay_plugins && \
    SHA=$(git ls-remote https://github.com/teamspatzenhirn/rviz_2d_overlay_plugins.git refs/heads/main | cut -f1) && [ -n "$SHA" ] && \
    wget --tries=5 --retry-connrefused --retry-on-http-error=429,500,502,503,504 --waitretry=10 --timeout=30 -O /tmp/repo_archive.tar.gz https://github.com/teamspatzenhirn/rviz_2d_overlay_plugins/archive/${SHA}.tar.gz && \
    tar -xzf /tmp/repo_archive.tar.gz -C /aas/github_ws/src/rviz_2d_overlay_plugins --strip-components=1 && rm /tmp/repo_archive.tar.gz && \
    echo "rviz_2d_overlay_plugins main ${SHA} $(find /aas/github_ws/src/rviz_2d_overlay_plugins -maxdepth 1 -type f -printf '%TF\n' | head -1)" >> /aas/repo_dep_branch_heads.txt
WORKDIR /aas/github_ws
# Explicitly use bash, not sh, to source and build the workspace
RUN bash -c "source /opt/ros/jazzy/setup.bash && colcon build --packages-select rviz_2d_overlay_msgs rviz_2d_overlay_plugins --cmake-args -DCMAKE_BUILD_TYPE=Release"

# Install SuperOdom, based on https://github.com/superxslam/SuperOdom#-3-installation
COPY /_github_clones/SuperOdom /aas/github_ws/src/SuperOdom
WORKDIR /aas/github_ws
# Explicitly use bash, not sh, to source and build the workspace
RUN bash -c "source /opt/ros/jazzy/setup.bash && source /aas/github_ws/install/setup.bash && colcon build --packages-up-to super_odometry --cmake-args -DCMAKE_BUILD_TYPE=Release"

# Install KISS-Matcher, based on https://github.com/MIT-SPARK/KISS-Matcher/tree/main/ros#gear-how-to-build--run
COPY /_github_clones/KISS-Matcher /aas/github_ws/src/KISS-Matcher
WORKDIR /aas/github_ws
# Explicitly use bash, not sh, to source and build the workspace
RUN bash -c "source /opt/ros/jazzy/setup.bash && colcon build --packages-select kiss_matcher_ros --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF"

# Install mimosa, based on https://github.com/ntnu-arl/mimosa/tree/dev/ros2#common-setup
RUN apt-get update && \
    apt-get install -y --no-install-recommends libgoogle-glog-dev libspdlog-dev ros-jazzy-pcl-ros \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /aas/mimosa_custom_gtsam_ws/src
COPY /_github_clones/mimosa /aas/mimosa_custom_gtsam_ws/src/mimosa
# Download config_utilities (branch: dev/mimosa), gtsam (commit c952ef9, see issue: https://github.com/ntnu-arl/mimosa/issues/19), and gtsam_points (branch: minimal_updated)
RUN mkdir -p config_utilities \
    && SHA=$(git ls-remote https://github.com/ntnu-arl/config_utilities.git refs/heads/dev/mimosa | cut -f1) && [ -n "$SHA" ] \
    && wget --tries=5 --retry-connrefused --retry-on-http-error=429,500,502,503,504 --waitretry=10 --timeout=30 -O /tmp/repo_archive.tar.gz https://github.com/ntnu-arl/config_utilities/archive/${SHA}.tar.gz \
    && tar -xzf /tmp/repo_archive.tar.gz -C config_utilities --strip-components=1 && rm /tmp/repo_archive.tar.gz \
    && echo "config_utilities dev/mimosa ${SHA} $(find config_utilities -maxdepth 1 -type f -printf '%TF\n' | head -1)" >> /aas/repo_dep_branch_heads.txt
RUN mkdir -p gtsam \
    && wget --tries=5 --retry-connrefused --retry-on-http-error=429,500,502,503,504 --waitretry=10 --timeout=30 -O /tmp/repo_archive.tar.gz https://github.com/ntnu-arl/gtsam/archive/c952ef9.tar.gz \
    && tar -xzf /tmp/repo_archive.tar.gz -C gtsam --strip-components=1 && rm /tmp/repo_archive.tar.gz
RUN mkdir -p gtsam_points \
    && SHA=$(git ls-remote https://github.com/ntnu-arl/gtsam_points.git refs/heads/minimal_updated | cut -f1) && [ -n "$SHA" ] \
    && wget --tries=5 --retry-connrefused --retry-on-http-error=429,500,502,503,504 --waitretry=10 --timeout=30 -O /tmp/repo_archive.tar.gz https://github.com/ntnu-arl/gtsam_points/archive/${SHA}.tar.gz \
    && tar -xzf /tmp/repo_archive.tar.gz -C gtsam_points --strip-components=1 && rm /tmp/repo_archive.tar.gz \
    && echo "gtsam_points minimal_updated ${SHA} $(find gtsam_points -maxdepth 1 -type f -printf '%TF\n' | head -1)" >> /aas/repo_dep_branch_heads.txt
WORKDIR /aas/mimosa_custom_gtsam_ws
# Explicitly use bash, not sh, to source and build the workspace
# Build mimosa's GTSAM fork and gtsam_points with -DBUILD_SHARED_LIBS=OFF -DGTSAM_BUILD_SHARED_LIBRARY=OFF, not to shadow the system-wide GTSAM used by SuperOdom, KISS-Matcher
RUN bash -c "source /opt/ros/jazzy/setup.bash && source /aas/github_ws/install/setup.bash && \
    colcon build --packages-select gtsam gtsam_points --cmake-args -DCMAKE_BUILD_TYPE=Release \
    -DGTSAM_POSE3_EXPMAP=ON -DGTSAM_ROT3_EXPMAP=ON -DGTSAM_USE_QUATERNIONS=ON -DGTSAM_USE_SYSTEM_EIGEN=ON -DGTSAM_BUILD_WITH_MARCH_NATIVE=OFF -DGTSAM_BUILD_EXAMPLES_ALWAYS=OFF -DGTSAM_WITH_TBB=OFF \
    -DBUILD_SHARED_LIBS=OFF -DGTSAM_BUILD_SHARED_LIBRARY=OFF \
    -DCMAKE_CXX_FLAGS=-Wno-error=overloaded-virtual"
# Build the rest of the mimosa workspace with the static GTSAM from mimosa's fork (limiting resource usage to avoid freezes on resource-constrained hosts)
RUN MAKEFLAGS='-j4' NINJAJOBS='-j4' bash -c "source /opt/ros/jazzy/setup.bash && source /aas/github_ws/install/setup.bash && source /aas/mimosa_custom_gtsam_ws/install/setup.bash && \
    colcon build --packages-up-to mimosa --packages-skip gtsam gtsam_points --cmake-args -DCMAKE_BUILD_TYPE=Release -DCONFIG_UTILS_BUILD_TESTS=OFF -DCONFIG_UTILS_BUILD_DEMOS=OFF"

# Install rovio (ROS 2 porting of https://github.com/ethz-asl/rovio), based on https://github.com/JacopoPan/rovio_ros2#installation
RUN apt-get update && \
    apt-get install -y --no-install-recommends freeglut3-dev libglew-dev \
    # valgrind \
    && apt clean \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir kindr \
    && SHA=$(git ls-remote https://github.com/ethz-asl/kindr.git refs/heads/master | cut -f1) && [ -n "$SHA" ] \
    && wget --tries=5 --retry-connrefused --retry-on-http-error=429,500,502,503,504 --waitretry=10 --timeout=30 -O /tmp/repo_archive.tar.gz https://github.com/ethz-asl/kindr/archive/${SHA}.tar.gz \
    && tar -xzf /tmp/repo_archive.tar.gz -C kindr --strip-components=1 && rm /tmp/repo_archive.tar.gz \
    && echo "kindr master ${SHA} $(find kindr -maxdepth 1 -type f -printf '%TF\n' | head -1)" >> /aas/repo_dep_branch_heads.txt \
    && cd kindr \
    && mkdir build && cd build \
    && cmake .. \
    && make install
COPY /_github_clones/rovio /aas/github_ws/src/rovio
WORKDIR /aas/github_ws
# Explicitly use bash, not sh, to source and build the workspace
RUN bash -c "source /opt/ros/jazzy/setup.bash && source /aas/github_ws/install/setup.bash && source /aas/mimosa_custom_gtsam_ws/install/setup.bash && \
    colcon build --packages-up-to rovio --cmake-args -DCMAKE_BUILD_TYPE=Release -DMAKE_SCENE=ON -DENABLE_VALGRIND_COMPATIBILITY=OFF -DBUILD_TESTING=OFF"

################################################################################
# Add analysis tools and YOLO models ###########################################
################################################################################
FROM advanced-odom-${BUILD_ADVANCED_ODOM} AS ros2-px4msgs-dds-mavros-yolo-ort-odom-analysis-models-image

# Add pymavlink for debugging and MAVROS's Python tools
RUN pip3 install --no-cache-dir --retries 5 pymavlink pyserial
# Check with $ python3 -c "import pymavlink; print(pymavlink.__version__)"
# Add the MCAP storage plugin for the rosbags
RUN apt-get update && \
    apt-get install -y --no-install-recommends ros-jazzy-rosbag2-storage-mcap \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

# Build Auterion/px4-ros2-interface-lib
COPY /_github_clones/px4-ros2-interface-lib/px4_ros2_cpp /aas/github_ws/src/px4_ros2_cpp
WORKDIR /aas/github_ws
RUN bash -c "source /opt/ros/jazzy/setup.bash && source /aas/github_ws/install/setup.bash && colcon build --symlink-install --packages-select px4_ros2_cpp --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF"

# Save the YOLO model weights (ONNX, Opset 12, FP32 for CPU ONNX Runtime) and class names
WORKDIR /aas/yolo
RUN /yolo-env/bin/python3 -c "from ultralytics import YOLO; YOLO('yolo26n.pt').export(format='onnx', opset=12, imgsz=640, nms=True)" && \
    mv yolo26n.onnx yolo26n_640.onnx && \
    /yolo-env/bin/python3 -c "from ultralytics import YOLO; YOLO('yolo26n.pt').export(format='onnx', opset=12, imgsz=320, nms=True)" && \
    mv yolo26n.onnx yolo26n_320.onnx && \
    /yolo-env/bin/python3 -c "import json; from ultralytics import YOLO; print(json.dumps(YOLO('yolo26n.pt').names))" | grep '{' > coco.json && \
    rm yolo26n.pt

################################################################################
# Copy AAS resources and build AAS ROS2 workspace ##############################
################################################################################
FROM ros2-px4msgs-dds-mavros-yolo-ort-odom-analysis-models-image AS aircraft-manifests

# Keep only the package.xml files, so rosdep re-runs only when dependencies change (for offline builds)
COPY ground/ground_ws/src/ground_system_msgs /src/ground_system_msgs
COPY aircraft/aircraft_ws/src /src
RUN find /src -type f ! -name package.xml -delete

FROM ros2-px4msgs-dds-mavros-yolo-ort-odom-analysis-models-image AS aircraft-dev-image

# Install the ROS 2 workspace dependencies (NOTE: also includes ground_system_msgs from the ground_ws)
COPY --from=aircraft-manifests /src /aas/aircraft_ws/src
WORKDIR /aas/aircraft_ws
RUN sed -i "/osx-homebrew/d" /etc/ros/rosdep/sources.list.d/20-default.list && (rosdep update --rosdistro jazzy || rosdep update --rosdistro jazzy)
RUN apt update && apt install -y python3-simpleeval && rosdep install --from-paths src/ --ignore-src --rosdistro jazzy -y --skip-keys "px4_msgs px4_ros2_cpp" && apt clean && rm -rf /var/lib/apt/lists/*

# Build the ROS 2 workspace (NOTE: also includes ground_system_msgs from the ground_ws)
COPY ground/ground_ws/src/ground_system_msgs /aas/aircraft_ws/src/ground_system_msgs
COPY aircraft/aircraft_ws/src /aas/aircraft_ws/src
COPY tools_and_docs/tests/.clang-tidy /aas/aircraft_ws/src/.clang-tidy
# Explicitly use bash, not sh, to source and build the workspace
RUN bash -c "source /opt/ros/jazzy/setup.bash && source /aas/github_ws/install/setup.bash && colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release"

# Copy resources and configuration files from this repository
COPY aircraft/aircraft_resources/ /aas/aircraft_resources
COPY aircraft/aircraft_resources/patches/kiss_icp.rviz /aas/github_ws/src/kiss-icp/ros/rviz/kiss_icp.rviz
COPY aircraft/aircraft_resources/patches/apm_pluginlists.yaml /opt/ros/jazzy/share/mavros/launch/apm_pluginlists.yaml
RUN ln -s /aas/aircraft_resources/patches/cancellable_action.py /usr/local/bin/cancellable_action \
    && chmod +x /aas/aircraft_resources/patches/cancellable_action.py

# Copy sensor configuration
COPY simulation/simulation_resources/aircraft_models/sensor_config.yaml /aas/aircraft_resources/sensor_config.yaml

# Source the workspaces for interactive shells
RUN echo "[ -f /aas/mimosa_custom_gtsam_ws/install/local_setup.bash ] && source /aas/mimosa_custom_gtsam_ws/install/local_setup.bash" >> /root/.bashrc \
    && echo "source /aas/github_ws/install/local_setup.bash" >> /root/.bashrc \
    && echo "source /aas/aircraft_ws/install/local_setup.bash" >> /root/.bashrc

# Create entrypoint to sync X11 cookie and load all ROS 2 overlays before tmuxinator or docker exec
RUN printf '#!/usr/bin/env bash\nset -e\nif [ -f /root/.Xauthority.ro ]; then\n    cp /root/.Xauthority.ro /tmp/.Xauthority\n    chmod 600 /tmp/.Xauthority\nfi\nexport XAUTHORITY=/tmp/.Xauthority\nsource /opt/ros/jazzy/setup.bash\n[ -f /aas/mimosa_custom_gtsam_ws/install/local_setup.bash ] && source /aas/mimosa_custom_gtsam_ws/install/local_setup.bash\n[ -f /aas/github_ws/install/local_setup.bash ] && source /aas/github_ws/install/local_setup.bash\n[ -f /aas/aircraft_ws/install/local_setup.bash ] && source /aas/aircraft_ws/install/local_setup.bash\nexec "$@"\n' > /aircraft_entrypoint.sh \
    && chmod +x /aircraft_entrypoint.sh

# Final config
WORKDIR /aas
COPY aircraft/aircraft.yml.erb /aas/aircraft.yml.erb
COPY simulation/simulation_resources/patches/tmux.conf /root/.tmux.conf
ENTRYPOINT ["/aircraft_entrypoint.sh", "tmuxinator", "start", "-p", "/aas/aircraft.yml.erb"]