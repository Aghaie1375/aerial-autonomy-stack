################################################################################
# Import ROS2 layer from aircraft.dockerfile ###################################
################################################################################
FROM transitional-ros2-image AS ros2-image

################################################################################
# Add QGroundControl and Betaflight App ########################################
################################################################################
FROM ros2-image AS ros2-gcs-image

# QGroundControl (as qgcuser)
# Ensure qgcuser belongs to dialout, video, and AMD render group (GID 988 on host)
WORKDIR /
RUN groupadd -g 988 -o render_host \
    && useradd -m -s /bin/bash -u 1000 -o qgcuser \
    && usermod -aG dialout,video,render_host qgcuser

RUN apt update \
    && apt install -y --no-install-recommends \
    libfuse2 libxcb-xinerama0 libxkbcommon-x11-0 libxcb-cursor0 \
    libgl1 libnss3 libasound2t64 \
    && apt clean \
    && rm -rf /var/lib/apt/lists/* \
    && wget --tries=5 --retry-connrefused --retry-on-http-error=429,500,502,503,504 --waitretry=10 --timeout=30 -O /QGroundControl-x86_64.AppImage \
    https://github.com/mavlink/qgroundcontrol/releases/download/v5.1.5/QGroundControl-x86_64.AppImage \
    && chmod +x /QGroundControl-x86_64.AppImage \
    && /QGroundControl-x86_64.AppImage --appimage-extract \
    && rm /QGroundControl-x86_64.AppImage \
    && chmod -R a+rX /squashfs-root
# Run with $ gosu qgcuser vglrun /squashfs-root/AppRun

# Betaflight App 2026.6.2 pin (socat relays the SITLs to the ground container)
RUN wget --tries=5 --retry-connrefused --retry-on-http-error=429,500,502,503,504 --waitretry=10 --timeout=30 -O /betaflight-app.deb \
    https://github.com/betaflight/betaflight-configurator/releases/download/2026.6.2/Betaflight-2026.6.2-amd64.deb \
    && apt update && apt install -y --no-install-recommends /betaflight-app.deb socat \
    && rm /betaflight-app.deb && apt clean && rm -rf /var/lib/apt/lists/*
# Run with $ python3 /aas/ground_resources/scripts/betaflight_app.py tcp://127.0.0.1:5761

# Install wmctrl and xrandr to resize QGC/Betaflight App windows
RUN apt update \
    && apt install -y --no-install-recommends \
    wmctrl x11-xserver-utils \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

################################################################################
# Add GStreamer and MAVLink ####################################################
################################################################################
FROM ros2-gcs-image AS ros2-gcs-gst-mavlink-image

# Add GStreamer packages (including X11 video sinks and AMD VA-API support) to receive camera streams
RUN apt update \
    && apt install -y --no-install-recommends \
    gstreamer1.0-tools gstreamer1.0-x gstreamer1.0-vaapi \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
    mesa-va-drivers python3-gi gir1.2-gst-plugins-base-1.0 gir1.2-gstreamer-1.0 \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

# Add pymavlink to quickly inspect MAVLink streams
RUN pip3 install --no-cache-dir --retries 5 pymavlink pyserial
# Check with $ python3 -c "import pymavlink; print(pymavlink.__version__)"

# Install mavlink-router
RUN apt update \
    && apt install -y --no-install-recommends \
    git meson ninja-build pkg-config gcc g++ systemd \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*
COPY /_github_clones/mavlink-router /aas/github_apps/mavlink-router
WORKDIR /aas/github_apps/mavlink-router
RUN meson setup build . --buildtype=release \
    && ninja -C build \
    && ninja -C build install
# Check with $ mavlink-routerd --version

# Add MAVLink 2 C library
COPY /_github_clones/c_library_v2 /usr/local/include/mavlink/

################################################################################
# Copy AAS resources and build AAS ROS2 workspace ##############################
################################################################################
FROM ros2-gcs-gst-mavlink-image AS ground-manifests

# Keep only the package.xml files, so rosdep re-runs only when dependencies change (for offline builds)
COPY ground/ground_ws/src /src
RUN find /src -type f ! -name package.xml -delete

FROM ros2-gcs-gst-mavlink-image AS ground-dev-image

# Install the ROS 2 workspace dependencies
COPY --from=ground-manifests /src /aas/ground_ws/src
WORKDIR /aas/ground_ws
RUN sed -i "/osx-homebrew/d" /etc/ros/rosdep/sources.list.d/20-default.list && (rosdep update --rosdistro jazzy || rosdep update --rosdistro jazzy)
RUN apt update && rosdep install --from-paths src/ --ignore-src --rosdistro jazzy -y && apt clean && rm -rf /var/lib/apt/lists/*

# Build the ROS 2 workspace
COPY ground/ground_ws/src /aas/ground_ws/src
COPY tools_and_docs/tests/.clang-tidy /aas/ground_ws/src/.clang-tidy
# Explicitly use bash, not sh, to source and build the workspace
RUN bash -c "source /opt/ros/jazzy/setup.bash && (source /aas/github_ws/install/setup.bash || true) && colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release"

# Copy resources and configuration files from this repository (ensure qgcuser owns its config dir)
COPY ground/ground_resources/ /aas/ground_resources
COPY --chown=qgcuser:qgcuser ground/ground_resources/patches/QGroundControl.ini /home/qgcuser/.config/QGroundControl/QGroundControl.ini

# Source the workspaces for interactive shells
RUN echo "source /aas/ground_ws/install/local_setup.bash" >> /root/.bashrc

# Create entrypoint to sync X11 cookie for both root & qgcuser and load ROS 2 paths
RUN printf '#!/usr/bin/env bash\nset -e\nif [ -f /root/.Xauthority.ro ]; then\n    cp /root/.Xauthority.ro /tmp/.Xauthority\n    chmod 644 /tmp/.Xauthority\nfi\nexport XAUTHORITY=/tmp/.Xauthority\nsource /opt/ros/jazzy/setup.bash\n[ -f /aas/ground_ws/install/local_setup.bash ] && source /aas/ground_ws/install/local_setup.bash\nexec "$@"\n' > /ground_entrypoint.sh \
    && chmod +x /ground_entrypoint.sh

# Final config
WORKDIR /aas
COPY ground/ground.yml.erb /aas/ground.yml.erb
COPY simulation/simulation_resources/patches/tmux.conf /root/.tmux.conf
ENTRYPOINT ["/ground_entrypoint.sh", "tmuxinator", "start", "-p", "/aas/ground.yml.erb"]