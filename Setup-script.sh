#!/bin/bash
# Add sample commment
# ===== STEP 0: Script information and version =====
SCRIPT_VERSION="1.1.3"

# OS-specific Java versions
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS specific versions
  JAVA_8_VERSION="8.0.442-zulu"
  JAVA_11_VERSION="11.0.26-zulu"
else
  # Windows/other OS versions
  JAVA_8_VERSION="8.0.45-zulu"
  JAVA_11_VERSION="11.0.26-zulu"
fi

MAVEN_VERSION="3.6.3"
SOURCE_DIR=""
PAYARA_DIR=""
LOG_FILE="setup_$(date +%Y%m%d_%H%M%S).log"

# ===== STEP 1: Setup logging (to both file and console) =====
if ( ls > >(cat) ) 2>/dev/null; then
  # If supported, use process substitution
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "[INFO] Logging to both console and $LOG_FILE."
else
  echo "[WARNING] Shell does not support process substitution."
  echo "[WARNING] Will only log to console, not writing to $LOG_FILE."
fi

# ===== UTILITY FUNCTIONS =====
show_banner() {
  echo "======================================================"
  echo "  Card App Server Environment Setup Tool v${SCRIPT_VERSION}"
  echo "  Supports: macOS and Windows (with Git Bash/MSYS2)"
  echo "======================================================"
  echo ""
}

log_info() {
  echo -e "\033[0;34m[INFO]\033[0m $1"
}

log_success() {
  echo -e "\033[0;32m[SUCCESS]\033[0m $1"
}

log_warning() {
  echo -e "\033[0;33m[WARNING]\033[0m $1"
}

log_error() {
  echo -e "\033[0;31m[ERROR]\033[0m $1"
}

confirm_action() {
  read -p "$1 (y/n): " response
  case "$response" in
    [yY][eE][sS]|[yY])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

check_result() {
  # Save exit code to a temporary variable to avoid overwriting
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    log_error "$1"
    if [ "$2" == "exit" ]; then
      exit 1
    fi
    return 1
  else
    log_success "$3"
    return 0
  fi
}

create_backup() {
  local dir_to_backup=$1
  local backup_name
  backup_name=$(basename "$dir_to_backup")
  local backup_dir="${dir_to_backup}_backup_$(date +%Y%m%d_%H%M%S)"

  log_info "Creating backup of $dir_to_backup to $backup_dir"
  cp -r "$dir_to_backup" "$backup_dir"
  check_result "Failed to create backup" "continue" "Backup created successfully at $backup_dir"

  echo "$backup_dir"
}

# ===== (NEW) Check bash version to warn the user =====
check_bash_version() {
  # Extract the major part from BASH_VERSION
  local major
  major=$(echo "${BASH_VERSION}" | cut -d '.' -f1)

  # Warn if bash version is less than 4
  if [[ "$major" -lt 4 ]]; then
    log_warning "You are using bash version $BASH_VERSION. macOS often has older bash 3.x."
    log_warning "Some script features might not work optimally."
  fi
}

# ===== DETECTION FUNCTIONS =====
detect_os() {
  log_info "Detecting operating system..."
  case "$OSTYPE" in
    darwin*) OS="macos" ;;
    msys*|cygwin*|win*) OS="windows" ;;
    *) OS="unsupported" ;;
  esac

  log_info "Detected OS: $OS"
  if [[ "$OS" == "unsupported" ]]; then
    log_error "This operating system is not supported by this script."
    exit 1
  fi
}

auto_detect_config() {
  log_info "Auto-detecting configuration..."

  # Auto-detect Payara
  if [ -z "$PAYARA_DIR" ]; then
    for dir in "/opt/payara5" "$HOME/payara5" "$HOME/work/payara5" "/Applications/Payara5"; do
      if [ -d "$dir" ]; then
        PAYARA_DIR="$dir"
        log_success "Auto-detected Payara at: $PAYARA_DIR"
        break
      fi
    done
  fi

  # Auto-detect SOURCE_DIR if the script is run from a related directory
  if [ -z "$SOURCE_DIR" ]; then
    CURRENT_DIR=$(pwd)
    if [[ "$CURRENT_DIR" == */card-app-server* ]]; then
      SOURCE_DIR=$(echo "$CURRENT_DIR" | sed -E 's/(.*card-app-server).*/\1/')
      log_success "Auto-detected source directory: $SOURCE_DIR"
    fi
  fi
}

check_prerequisites() {
  log_info "Checking basic prerequisites..."

  # Check disk space
  if [[ "$OS" == "macos" ]]; then
    AVAILABLE_SPACE=$(df -h . | awk 'NR==2 {print $4}')
  elif [[ "$OS" == "windows" ]]; then
    AVAILABLE_SPACE=$(df -h . | awk 'NR==2 {print $4}')
  fi
  log_info "Available disk space: $AVAILABLE_SPACE"

  # Check if Docker is installed
  if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker --version)
    log_success "Docker is installed: $DOCKER_VERSION"
  else
    log_warning "Docker is not installed. Will be set up during the process."
  fi

  # Check if Java is installed
  if command -v java &> /dev/null; then
    JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    log_success "Java is installed: $JAVA_VERSION"
  else
    log_warning "Java is not installed. Will be set up during the process."
  fi
}

get_source_dir() {
  if [ -z "$SOURCE_DIR" ]; then
    log_info "Please enter the path to the source directory of card-app-server where the patch should be applied:"
    read -r SOURCE_DIR

    # Handle relative paths
    if [[ ! "$SOURCE_DIR" = /* ]] && [[ ! "$SOURCE_DIR" =~ ^[A-Za-z]: ]]; then
      SOURCE_DIR="$(pwd)/$SOURCE_DIR"
    fi

    # Remove trailing slash if any
    SOURCE_DIR=${SOURCE_DIR%/}
  fi

  if [ ! -d "$SOURCE_DIR" ]; then
    log_error "Directory not found at $SOURCE_DIR"
    if confirm_action "Would you like to enter a different path?"; then
      unset SOURCE_DIR
      get_source_dir
    else
      exit 1
    fi
  else
    log_success "Using source directory: $SOURCE_DIR"
  fi
}

# ===== SETUP FUNCTIONS =====
check_dependencies() {
  log_info "[INFO] Checking additional dependencies..."
  local deps=("curl" "zip" "unzip" "tar")
  local missing_deps=()
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      log_warning "$dep is not installed."
      missing_deps+=("$dep")
    else
      log_success "$dep is installed."
    fi
  done

  if [ ${#missing_deps[@]} -gt 0 ]; then
    log_info "Installing missing dependencies: ${missing_deps[*]}"

    if [[ "$OS" == "windows" ]]; then
      for dep in "${missing_deps[@]}"; do
        if [[ "$dep" == "zip" ]]; then
          log_info "Installing zip using winget..."
          winget install -e --id GnuWin32.Zip
          mkdir -p ~/bin
          cp /usr/bin/unzip.exe ~/bin/zip.exe 2>/dev/null || log_warning "Could not copy unzip.exe to ~/bin/zip.exe"
        else
          log_warning "Please install $dep via MSYS2 (e.g., 'pacman -S $dep')."
          if ! confirm_action "Continue without $dep?"; then
            exit 1
          fi
        fi
      done
    elif [[ "$OS" == "macos" ]]; then
      if ! command -v brew &> /dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        eval "$(/opt/homebrew/bin/brew shellenv)" || eval "$(/usr/local/bin/brew shellenv)"
      fi

      for dep in "${missing_deps[@]}"; do
        log_info "Installing $dep via Homebrew..."
        brew install "$dep"
        check_result "Failed to install $dep" "continue" "$dep installed successfully"
      done
    fi
  fi
}

setup_docker() {
  log_info "Setting up Docker..."

  # If Docker is installed but may be stopped => check and start it
  if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
      log_success "Docker is already running and configured properly."
      return 0
    else
      # Docker is installed but not running
      log_warning "Docker is installed but not running or has configuration issues."

      if [[ "$OS" == "windows" ]]; then
        # Attempt to start Docker Desktop on Windows
        log_warning "Attempting to start Docker Desktop on Windows..."
        WIN_DOCKER_DESKTOP_PATH="/c/Program Files/Docker/Docker/Docker Desktop.exe"

        if [[ -f "$WIN_DOCKER_DESKTOP_PATH" ]]; then
          ( "$WIN_DOCKER_DESKTOP_PATH" & )  # run in background
          local wait_time=0
          while ! docker info &>/dev/null; do
            sleep 3
            wait_time=$((wait_time+3))
            if [ $wait_time -gt 90 ]; then
              log_error "Docker Desktop did not start within 90 seconds. Please start it manually."
              return 1
            fi
            log_info "Waiting for Docker Desktop to start..."
          done
          log_success "Docker Desktop started and is now running."
          return 0
        else
          log_error "Cannot find Docker Desktop at $WIN_DOCKER_DESKTOP_PATH. Please start Docker manually."
          return 1
        fi
      fi
    fi
  fi

  # If code reaches here => Docker is not installed (or on macOS, Docker is stopped)
  if [[ "$OS" == "macos" ]]; then
    log_info "Setting up Docker with Colima for macOS (non-admin)..."
    if ! command -v brew &> /dev/null; then
      log_info "Installing Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      eval "$(/opt/homebrew/bin/brew shellenv)" || eval "$(/usr/local/bin/brew shellenv)"
    fi
    brew install docker docker-compose colima
    colima start --cpu 4 --memory 8 --arch x86_64
    docker context use colima
    check_result "Failed to set up Docker with Colima" "continue" "Docker setup completed. Run 'colima status' to check."
  elif [[ "$OS" == "windows" ]]; then
    log_info "For Windows without admin rights, Docker setup is manual:"
    log_info "1. Download Docker Desktop from https://www.docker.com/products/docker-desktop"
    log_info "2. Install it with the 'Install for me only' option (no admin rights needed)."
    log_info "Alternatively, use Docker Toolbox or set up WSL2 with Docker manually."

    if confirm_action "Have you already installed Docker Desktop?"; then
      log_success "Please start Docker Desktop manually and re-run the script."
    else
      log_info "Press any key to continue once Docker is set up..."
      read -n 1 -s
    fi
  fi

  # Finally, verify Docker
  if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
      log_success "Docker is now running properly."
      docker --version
    else
      log_error "Docker is installed but not running. Please start Docker and try again."
      return 1
    fi
  else
    log_error "Docker installation failed or is incomplete."
    return 1
  fi
}

setup_java() {
  log_info "Installing SDKMAN! and Java..."
  check_dependencies
  if ! command -v sdk &> /dev/null; then
    log_info "Installing SDKMAN!..."
    curl -s "https://get.sdkman.io" | bash
    if [ -f "$HOME/.sdkman/bin/sdkman-init.sh" ]; then
      source "$HOME/.sdkman/bin/sdkman-init.sh"
      sdk selfupdate force
    else
      log_error "SDKMAN! installation failed."
      exit 1
    fi
  else
    log_success "SDKMAN! is already installed."
    source "$HOME/.sdkman/bin/sdkman-init.sh"
  fi

  log_info "Installing Java 8 ($JAVA_8_VERSION)..."
  sdk install java "$JAVA_8_VERSION" || sdk install java "$JAVA_8_VERSION" --force
  check_result "Failed to install Java 8" "continue" "Java 8 installed successfully"

  log_info "Installing Java 11 ($JAVA_11_VERSION)..."
  sdk install java "$JAVA_11_VERSION" || sdk install java "$JAVA_11_VERSION" --force
  check_result "Failed to install Java 11" "continue" "Java 11 installed successfully"

  log_success "Java installation completed."
}

setup_java_home() {
  log_info "[INFO] Setting up Java environment variables and aliases..."

  # Rename function to java8() & java11()
  cat > ~/.java_switcher << EOF
#!/bin/bash

function java8() {
  sdk use java $JAVA_8_VERSION
  echo "Switched to Java 8 ($JAVA_8_VERSION)"
}

function java11() {
  sdk use java $JAVA_11_VERSION
  echo "Switched to Java 11 ($JAVA_11_VERSION)"
}

export -f java8
export -f java11
EOF

  if [[ "$OS" == "macos" ]]; then
    # macOS
    if [[ "$SHELL" == */zsh ]]; then
      if ! grep -q "source ~/.java_switcher" ~/.zshrc; then
        echo "source ~/.java_switcher" >> ~/.zshrc
        echo "alias java8='java8'" >> ~/.zshrc
        echo "alias java11='java11'" >> ~/.zshrc
      fi
    else
      if ! grep -q "source ~/.java_switcher" ~/.bash_profile; then
        echo "source ~/.java_switcher" >> ~/.bash_profile
        echo "alias java8='java8'" >> ~/.bash_profile
        echo "alias java11='java11'" >> ~/.bash_profile
      fi
    fi
  elif [[ "$OS" == "windows" ]]; then
    # Git Bash/MSYS2
    if ! grep -q "source ~/.java_switcher" ~/.bashrc; then
      echo "source ~/.java_switcher" >> ~/.bashrc
      echo "alias java8='java8'" >> ~/.bashrc
      echo "alias java11='java11'" >> ~/.bashrc
    fi
  fi

  # Source immediately to apply changes
  source ~/.java_switcher
  log_success "Java environment setup completed. Use 'java8' or 'java11' to switch."
}

setup_maven() {
  log_info "[INFO] Installing Maven $MAVEN_VERSION through SDKMAN!..."
  if ! command -v sdk &> /dev/null; then
    log_error "SDKMAN! is not installed. Please run setup_java first."
    return 1
  fi

  if sdk list maven | grep -q " \* $MAVEN_VERSION"; then
    log_success "Maven $MAVEN_VERSION is already installed."
  else
    sdk install maven "$MAVEN_VERSION"
    check_result "Failed to install Maven" "continue" "Maven $MAVEN_VERSION installed successfully"
  fi

  sdk default maven "$MAVEN_VERSION"
  mkdir -p ~/.m2
  REPO_PATH="file://${HOME}/.m2/repository"
  LOCAL_REPO="${HOME}/.m2/repository"

  if [ -f "./settings.xml" ]; then
    log_info "Configuring Maven settings.xml..."
    cp ./settings.xml ~/.m2/settings.xml
    if [[ "$OS" == "macos" ]]; then
      sed -i '' "s|<url>file:///C:\\\\Users\\\\[^/]*\\\\.m2\\\\repository</url>|<url>${REPO_PATH}</url>|g" ~/.m2/settings.xml
      sed -i '' "s|<localRepository>.*</localRepository>|<localRepository>${LOCAL_REPO}</localRepository>|g" ~/.m2/settings.xml
    elif [[ "$OS" == "windows" ]]; then
      sed -i "s|<url>file:///C:\\\\Users\\\\[^/]*\\\\.m2\\\\repository</url>|<url>${REPO_PATH}</url>|g" ~/.m2/settings.xml
      sed -i "s|<localRepository>.*</localRepository>|<localRepository>${LOCAL_REPO}</localRepository>|g" ~/.m2/settings.xml
    fi
    log_success "Maven settings.xml configured with repository path: ${REPO_PATH}"
  else
    log_warning "settings.xml not found. Creating default settings.xml..."
    cat > ~/.m2/settings.xml << EOF
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                      http://maven.apache.org/xsd/settings-1.0.0.xsd">
  <localRepository>${LOCAL_REPO}</localRepository>
  <profiles>
    <profile>
      <id>default</id>
      <repositories>
        <repository>
          <id>local</id>
          <url>${REPO_PATH}</url>
        </repository>
      </repositories>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>default</activeProfile>
  </activeProfiles>
</settings>
EOF
    log_success "Default Maven settings.xml created."
  fi

  log_success "Maven ($MAVEN_VERSION) installation and configuration completed."
}

apply_patch() {
  log_info "Preparing to apply Setup-local-v2.patch..."
  SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  PATCH_FILE="$SCRIPT_DIR/Setup-local-v2.patch"

  if [ ! -f "$PATCH_FILE" ]; then
    log_error "Patch file not found at $PATCH_FILE"
    log_info "Please ensure 'Setup-local-v2.patch' is in the same directory as this script."
    return 1
  fi

  cd "$SOURCE_DIR" || return 1

  # Create a backup before applying the patch
  if confirm_action "Do you want to create a backup before applying the patch?"; then
    BACKUP_DIR=$(create_backup "$SOURCE_DIR")
    log_info "If the patch fails, you can restore from: $BACKUP_DIR"
  fi

  PATCH_ALREADY_APPLIED=false
  if [ -d ".git" ]; then
    if ! git apply --check "$PATCH_FILE" 2>/dev/null; then
      log_warning "It appears the patch may have been applied already or there are conflicts."
      PATCH_ALREADY_APPLIED=true
    fi
  else
    if ! patch --dry-run -p1 < "$PATCH_FILE" &>/dev/null; then
      log_warning "It appears the patch may have been applied already or there are conflicts."
      PATCH_ALREADY_APPLIED=true
    fi
  fi

  if [ "$PATCH_ALREADY_APPLIED" = true ]; then
    if confirm_action "Do you want to force apply the patch anyway?"; then
      log_info "Proceeding with force application of patch..."
    else
      log_info "Patch application cancelled by user."
      return 0
    fi
  fi

  if [ -d ".git" ]; then
    if git apply --check "$PATCH_FILE" 2>/dev/null || [ "$PATCH_ALREADY_APPLIED" = true ]; then
      if [ "$PATCH_ALREADY_APPLIED" = true ]; then
        git apply --reject "$PATCH_FILE" 2>/dev/null || true
        log_warning "Patch applied with possible rejections. Check .rej files if any."
      else
        git apply "$PATCH_FILE"
        log_success "Patch applied successfully using git apply!"
      fi
    else
      log_info "Trying with standard patch command..."
      if patch -p1 --force < "$PATCH_FILE"; then
        log_success "Patch applied successfully using patch command!"
      else
        log_error "Failed to apply patch. There might be conflicts."
        log_info "Tip: Check for .rej files in the directory for rejected hunks."
        return 1
      fi
    fi
  else
    if [ "$PATCH_ALREADY_APPLIED" = true ]; then
      if patch -p1 --force < "$PATCH_FILE"; then
        log_warning "Patch applied with force option. Check for .rej files if any parts failed."
      else
        log_error "Failed to apply patch even with force option."
        return 1
      fi
    else
      if patch -p1 < "$PATCH_FILE"; then
        log_success "Patch applied successfully using patch command!"
      else
        log_error "Failed to apply patch. There might be conflicts."
        return 1
      fi
    fi
  fi

  return 0
}

setup_oracle() {
  log_info "Setting up Oracle database using docker-compose..."
  if ! command -v docker &> /dev/null; then
    log_error "Docker not found. Please ensure Docker is set up correctly."
    return 1
  fi

  # Check if Oracle container is already running
  if docker ps | grep -q "oracle"; then
    log_info "Oracle container is already running."
    if confirm_action "Do you want to recreate the Oracle containers?"; then
      log_info "Stopping existing Oracle containers..."
      docker stop $(docker ps -q --filter "name=oracle") 2>/dev/null
    else
      log_info "Skipping Oracle setup."
      return 0
    fi
  fi

  # Check if Oracle image already exists
  if docker images | grep -i "21.3.0-xe-builded"; then
    log_success "Oracle image already exists. Skipping image load."
  else
    log_info "Oracle image not found. Need to load from tar file..."

    ORACLE_IMAGE_LOCATIONS=(
      "./oracle-21.3.0-xe-builded.tar"
      "$HOME/Downloads/oracle-21.3.0-xe-builded.tar"
      "$SOURCE_DIR/oracle-21.3.0-xe-builded.tar"
    )
    ORACLE_IMAGE_FOUND=false
    for location in "${ORACLE_IMAGE_LOCATIONS[@]}"; do
      if [ -f "$location" ]; then
        log_info "Found Oracle image at: $location"
        ORACLE_IMAGE_PATH="$location"
        ORACLE_IMAGE_FOUND=true
        break
      fi
    done

    if [ "$ORACLE_IMAGE_FOUND" = false ]; then
      log_warning "Oracle image file not found in common locations."
      log_info "Please enter the full path to oracle-21.3.0-xe-builded.tar:"
      read -r ORACLE_IMAGE_PATH

      if [ ! -f "$ORACLE_IMAGE_PATH" ]; then
        log_error "File not found at: $ORACLE_IMAGE_PATH"
        log_info "Would you like to:"
        echo "1) Enter a different path"
        echo "2) Download the image (if you have a download URL)"
        echo "3) Skip Oracle setup"
        read -p "Enter your choice [1-3]: " oracle_choice

        case $oracle_choice in
          1)
            log_info "Please enter the correct path to oracle-21.3.0-xe-builded.tar:"
            read -r ORACLE_IMAGE_PATH
            if [ ! -f "$ORACLE_IMAGE_PATH" ]; then
              log_error "File still not found. Skipping Oracle setup."
              return 1
            fi
            ;;
          2)
            log_info "Please enter the download URL for the Oracle image:"
            read -r ORACLE_DOWNLOAD_URL

            log_info "Downloading Oracle image..."
            ORACLE_IMAGE_PATH="/tmp/oracle-21.3.0-xe-builded.tar"
            if curl -L -o "$ORACLE_IMAGE_PATH" "$ORACLE_DOWNLOAD_URL"; then
              log_success "Download completed successfully."
            else
              log_error "Failed to download Oracle image."
              return 1
            fi
            ;;
          3)
            log_info "Skipping Oracle setup."
            return 0
            ;;
          *)
            log_error "Invalid choice. Skipping Oracle setup."
            return 1
            ;;
        esac
      fi
    fi

    log_info "Loading Oracle image from $ORACLE_IMAGE_PATH..."
    docker load -i "$ORACLE_IMAGE_PATH"
    if [ $? -ne 0 ]; then
      log_error "Failed to load Oracle image."
      if confirm_action "Would you like to try loading the image with sudo?"; then
        log_info "Trying with sudo..."
        sudo docker load -i "$ORACLE_IMAGE_PATH"
        if [ $? -ne 0 ]; then
          log_error "Failed to load Oracle image even with sudo."
          return 1
        fi
      else
        return 1
      fi
    fi
    log_success "Loaded image oracle-21.3.0-xe-builded successfully"
  fi

  # Check directories
  if [ ! -d "$SOURCE_DIR/card-member-core/conte" ]; then
    log_error "Directory not found at $SOURCE_DIR/card-member-core/conte"
    return 1
  fi
  if [ ! -d "$SOURCE_DIR/card-ria/conte" ]; then
    log_error "Directory not found at $SOURCE_DIR/card-ria/conte"
    return 1
  fi

  # Run docker-compose in directories
  log_info "Starting docker-compose in $SOURCE_DIR/card-member-core/conte..."
  cd "$SOURCE_DIR/card-member-core/conte" || return 1
  docker-compose up -d
  check_result "Failed to start Oracle containers for card-member-core" "continue" "Started Oracle containers for card-member-core successfully"

  log_info "Starting docker-compose in $SOURCE_DIR/card-ria/conte..."
  cd "$SOURCE_DIR/card-ria/conte" || return 1
  docker-compose up -d
  check_result "Failed to start Oracle containers for card-ria" "continue" "Started Oracle containers for card-ria successfully"

  log_success "Oracle database setup completed successfully."
  return 0
}

setup_payara() {
  log_info "Setting up Payara domains..."
  # Auto-detect or ask for Payara directory
  if [ -z "$PAYARA_DIR" ]; then
    log_info "Please enter the path to your Payara5 directory (e.g., /opt/payara5 or /Users/username/work/payara5):"
    read -r PAYARA_DIR
  else
    log_info "Using detected Payara directory: $PAYARA_DIR"
  fi

  if [ ! -d "$PAYARA_DIR" ]; then
    log_error "Payara directory not found at $PAYARA_DIR"
    return 1
  fi

  ASADMIN="$PAYARA_DIR/bin/asadmin"
  if [ ! -f "$ASADMIN" ]; then
    log_error "asadmin not found at $ASADMIN"
    return 1
  fi

  JAR_PATH="$SOURCE_DIR/card-member-core/conte/resources/ojdbc10.jar"
  if [ ! -f "$JAR_PATH" ]; then
    log_error "ojdbc10.jar not found in $JAR_PATH"
    return 1
  else
    log_success "File found, proceeding..."
    cp "$JAR_PATH" "$PAYARA_DIR/glassfish/lib/" && log_success "Copied: $JAR_PATH -> $PAYARA_DIR/glassfish/lib/ojdbc10.jar"
  fi

  chmod +x "$ASADMIN"
  JAVA_11_HOME="$HOME/.sdkman/candidates/java/$JAVA_11_VERSION"

  # Check if domains already exist
  if [ -d "$PAYARA_DIR/glassfish/domains/ria" ]; then
    log_warning "Domain 'ria' already exists."
    if confirm_action "Do you want to recreate the 'ria' domain?"; then
      log_info "Deleting existing 'ria' domain..."
      $ASADMIN delete-domain ria
    else
      log_info "Skipping 'ria' domain creation."
    fi
  fi

  if [ -d "$PAYARA_DIR/glassfish/domains/member-core" ]; then
    log_warning "Domain 'member-core' already exists."
    if confirm_action "Do you want to recreate the 'member-core' domain?"; then
      log_info "Deleting existing 'member-core' domain..."
      $ASADMIN delete-domain member-core
    else
      log_info "Skipping 'member-core' domain creation."
    fi
  fi

  # Create and configure RIA domain if needed
  if [ ! -d "$PAYARA_DIR/glassfish/domains/ria" ]; then
    log_info "Creating and configuring RIA domain..."
    $ASADMIN create-domain --nopassword --portbase 8000 ria
    check_result "Failed to create RIA domain" "continue" "RIA domain created successfully"

    $ASADMIN start-domain ria
    $ASADMIN --port 8048 set configs.config.server-config.java-config.java-home="$JAVA_11_HOME"
    $ASADMIN --port 8048 create-jvm-options '-Xmx1g'
    $ASADMIN --port 8048 delete-jvm-options '-Xmx512m'
    $ASADMIN stop-domain ria
    log_success "RIA domain configured successfully"
  fi

  # Create and configure MEMBER-CORE domain if needed
  if [ ! -d "$PAYARA_DIR/glassfish/domains/member-core" ]; then
    log_info "Creating and configuring MEMBER-CORE domain..."
    $ASADMIN create-domain --nopassword --portbase 8100 member-core
    check_result "Failed to create MEMBER-CORE domain" "continue" "MEMBER-CORE domain created successfully"

    $ASADMIN start-domain member-core
    $ASADMIN --port 8148 set configs.config.server-config.java-config.java-home="$JAVA_11_HOME"
    $ASADMIN --port 8148 create-jdbc-connection-pool \
      --datasourceclassname oracle.jdbc.pool.OracleDataSource \
      --restype javax.sql.DataSource \
      --property url="jdbc\:oracle\:thin\:@//localhost\:1521/xepdb1":user="card_core":password="rakutencard_local" card-core-pool
    $ASADMIN --port 8148 create-jdbc-resource --connectionpoolid card-core-pool jdbc/card_core
    $ASADMIN --port 8148 create-jvm-options '-Xmx1g'
    $ASADMIN --port 8148 delete-jvm-options '-Xmx512m'
    $ASADMIN stop-domain member-core
    log_success "MEMBER-CORE domain configured successfully"
  fi

  log_success "Payara domains setup completed successfully!"
  return 0
}

copy_folders_and_files() {
  log_info "[INFO] Copying required files and folders..."
  if [ -z "$PAYARA_DIR" ]; then
    log_info "Please enter the path to your Payara5 directory (e.g., /opt/payara5 or /Users/username/work/payara5):"
    read -r PAYARA_DIR
  fi

  if [ ! -d "$PAYARA_DIR" ]; then
    log_error "Payara directory not found at $PAYARA_DIR"
    return 1
  fi

  JAR_PATH="$SOURCE_DIR/card-member-core/conte/resources/ojdbc10.jar"
  if [ ! -f "$JAR_PATH" ]; then
    log_error "ojdbc10.jar not found in $JAR_PATH"
    return 1
  fi

  log_info "Copying ojdbc10.jar into Payara glassfish/lib..."
  cp "$JAR_PATH" "$PAYARA_DIR/glassfish/lib/" 2>/dev/null ||
    sudo cp "$JAR_PATH" "$PAYARA_DIR/glassfish/lib/"
  check_result "Failed to copy ojdbc10.jar" "continue" "Copied: $JAR_PATH -> $PAYARA_DIR/glassfish/lib/ojdbc10.jar"

  log_success "File and directory copying completed successfully."
  return 0
}

cleanup() {
  log_info "[INFO] Cleaning up temporary files..."
  find . -name "*.tmp" -type f -delete
  find . -name "*.bak" -type f -delete

  # Remove old log files (older than 7 days)
  find . -name "setup_*.log" -type f -mtime +7 -delete

  log_success "Cleanup completed."
}

show_completion_message() {
  echo ""
  echo "======================================================"
  echo "  Setup Completed Successfully!"
  echo "======================================================"
  echo ""
  echo "Summary of installed components:"

  if command -v docker &> /dev/null; then
    echo "✓ Docker: $(docker --version)"
  fi

  if command -v java &> /dev/null; then
    echo "✓ Java: $(java -version 2>&1 | awk -F '\"' '/version/ {print $2}')"
  fi

  if command -v mvn &> /dev/null; then
    echo "✓ Maven: $(mvn --version | head -n 1)"
  fi

  if [ -d "$PAYARA_DIR" ]; then
    echo "✓ Payara domains: ria, member-core"
  fi

  if docker ps | grep -q "oracle"; then
    echo "✓ Oracle database: Running"
  fi

  echo ""
  echo "Next steps:"
  echo "1. Restart your terminal or run:"
  if [[ "$OS" == "macos" ]]; then
    if [[ "$SHELL" == */zsh ]]; then
      echo "   source ~/.zshrc"
    else
      echo "   source ~/.bash_profile"
    fi
  elif [[ "$OS" == "windows" ]]; then
    echo "   source ~/.bashrc (for Git Bash/WSL)"
  fi
  echo "2. Use 'java8' or 'java11' commands to switch Java versions (alias for functions java8/java11)."
  echo "3. Start developing with your configured environment!"
  echo ""
  echo "For any issues, please check the log file: $LOG_FILE"
  echo "======================================================"
}

run_all_steps() {
  log_info "[ALL-STEPS] Begin full setup sequence..."
  log_info "-----------------------------------------------"
  get_source_dir
  setup_docker
  setup_java
  setup_java_home
  setup_maven
  apply_patch
  setup_oracle
  setup_payara
  copy_folders_and_files
  cleanup
  show_completion_message
}

show_menu() {
  echo "Please select an option:"
  echo "1) Setup complete environment (all steps)"
  echo "2) Setup Docker only"
  echo "3) Setup Java and Maven only"
  echo "4) Apply patch only"
  echo "5) Setup Oracle database only"
  echo "6) Setup Payara domains only"
  echo "7) Copy required folders and files only"
  echo "8) Exit"
  read -p "Enter your choice [1-8]: " choice

  case $choice in
    1) run_all_steps ;;
    2) setup_docker ;;
    3) setup_java && setup_java_home && setup_maven ;;
    4) get_source_dir && apply_patch ;;
    5) get_source_dir && setup_oracle ;;
    6) get_source_dir && setup_payara ;;
    7) get_source_dir && copy_folders_and_files ;;
    8) exit 0 ;;
    *) echo "Invalid option. Please try again." && show_menu ;;
  esac
}

main() {
  show_banner
  check_bash_version   # (NEW) Check bash version to warn the user
  detect_os
  check_prerequisites
  auto_detect_config

  if [ $# -eq 0 ]; then
    # Interactive mode
    show_menu
  else
    # Command line mode
    case "$1" in
      --all) run_all_steps ;;
      --docker) setup_docker ;;
      --java) setup_java && setup_java_home && setup_maven ;;
      --patch) get_source_dir && apply_patch ;;
      --oracle) get_source_dir && setup_oracle ;;
      --payara) get_source_dir && setup_payara ;;
      --copy) get_source_dir && copy_folders_and_files ;;
      --help)
        echo "Usage: $0 [OPTION]"
        echo "Options:"
        echo "  --all     Run all setup steps"
        echo "  --docker  Setup Docker only"
        echo "  --java    Setup Java and Maven only"
        echo "  --patch   Apply patch only"
        echo "  --oracle  Setup Oracle database only"
        echo "  --payara  Setup Payara domains only"
        echo "  --copy    Copy required folders and files only"
        echo "  --help    Display this help message"
        ;;
      *)
        echo "Unknown option: $1"
        echo "Use --help for usage information."
        exit 1
        ;;
    esac
  fi
}

main "$@"
