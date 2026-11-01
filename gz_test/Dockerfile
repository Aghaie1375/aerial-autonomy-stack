FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies and Mesa OpenGL / Vulkan drivers for AMD
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
    lsb-release \
    mesa-utils \
    mesa-vulkan-drivers \
    libgl1-mesa-dri \
    && rm -rf /var/lib/apt/lists/*

# Add Gazebo package repository
RUN curl https://packages.osrfoundation.org/gazebo.gpg --output /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] http://packages.osrfoundation.org/gazebo/ubuntu-stable $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/gazebo-stable.list > /dev/null

# Install Gazebo Harmonic
RUN apt-get update && apt-get install -y \
    gz-harmonic \
    && rm -rf /var/lib/apt/lists/*

ENV QT_X11_NO_MITSHM=1
CMD ["bash"]