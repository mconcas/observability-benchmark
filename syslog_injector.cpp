#include <iostream>
#include <fstream>
#include <string>
#include <chrono>
#include <thread>
#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <ctime>
#include <atomic>
#include <signal.h>
#include <iomanip>
#include <vector>
#include <sstream>

// Global flag for signal handling
std::atomic<bool> running(true);

struct Config {
    std::string socket_path;
    std::string message_format;
    int target_rate;        // messages per second
    int duration;           // test duration in seconds
    int batch_size;         // messages per batch
    bool verbose;
};

struct Stats {
    std::atomic<uint64_t> messages_sent{0};
    std::atomic<uint64_t> bytes_sent{0};
    std::atomic<uint64_t> errors{0};
    std::chrono::steady_clock::time_point start_time;
};

void signal_handler(int) {
    running = false;
}

Config load_config(const std::string& config_file) {
    Config config;
    // Default values
    config.socket_path = "/tmp/fluentbit.sock";
    config.message_format = "<134>1 {timestamp} {hostname} test-app {pid} - - Test message #{counter}";
    config.target_rate = 1000;
    config.duration = 60;
    config.batch_size = 100;
    config.verbose = false;

    std::ifstream file(config_file);
    if (!file.is_open()) {
        std::cerr << "Warning: Could not open config file '" << config_file
                  << "', using defaults" << std::endl;
        return config;
    }

    std::string line;
    while (std::getline(file, line)) {
        // Skip comments and empty lines
        if (line.empty() || line[0] == '#') continue;

        size_t pos = line.find('=');
        if (pos == std::string::npos) continue;

        std::string key = line.substr(0, pos);
        std::string value = line.substr(pos + 1);

        // Trim whitespace
        key.erase(0, key.find_first_not_of(" \t"));
        key.erase(key.find_last_not_of(" \t") + 1);
        value.erase(0, value.find_first_not_of(" \t"));
        value.erase(value.find_last_not_of(" \t") + 1);

        if (key == "socket_path") config.socket_path = value;
        else if (key == "message_format") config.message_format = value;
        else if (key == "target_rate") config.target_rate = std::stoi(value);
        else if (key == "duration") config.duration = std::stoi(value);
        else if (key == "batch_size") config.batch_size = std::stoi(value);
        else if (key == "verbose") config.verbose = (value == "true" || value == "1");
    }

    return config;
}

std::string format_message(const std::string& format_template, uint64_t counter) {
    std::string result = format_template;

    // Replace {counter}
    size_t pos = result.find("{counter}");
    if (pos != std::string::npos) {
        result.replace(pos, 9, std::to_string(counter));
    }

    // Replace {timestamp} with RFC3339 timestamp
    pos = result.find("{timestamp}");
    if (pos != std::string::npos) {
        auto now = std::chrono::system_clock::now();
        auto time_t_now = std::chrono::system_clock::to_time_t(now);
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            now.time_since_epoch()) % 1000;

        std::ostringstream oss;
        oss << std::put_time(std::gmtime(&time_t_now), "%Y-%m-%dT%H:%M:%S")
            << '.' << std::setfill('0') << std::setw(3) << ms.count() << 'Z';
        result.replace(pos, 11, oss.str());
    }

    // Replace {hostname}
    pos = result.find("{hostname}");
    if (pos != std::string::npos) {
        char hostname[256];
        gethostname(hostname, sizeof(hostname));
        result.replace(pos, 10, hostname);
    }

    // Replace {pid}
    pos = result.find("{pid}");
    if (pos != std::string::npos) {
        result.replace(pos, 5, std::to_string(getpid()));
    }

    return result;
}

int connect_to_socket(const std::string& socket_path) {
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) {
        std::cerr << "Error creating socket: " << strerror(errno) << std::endl;
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path.c_str(), sizeof(addr.sun_path) - 1);

    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        std::cerr << "Error connecting to socket '" << socket_path
                  << "': " << strerror(errno) << std::endl;
        close(sock);
        return -1;
    }

    return sock;
}

void print_stats(const Stats& stats, bool final = false) {
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        now - stats.start_time).count() / 1000.0;

    uint64_t messages = stats.messages_sent.load();
    uint64_t bytes = stats.bytes_sent.load();
    uint64_t errors = stats.errors.load();

    double msg_rate = elapsed > 0 ? messages / elapsed : 0;
    double byte_rate = elapsed > 0 ? bytes / elapsed : 0;

    std::cout << "\r" << (final ? "\n=== Final Statistics ===\n" : "")
              << "Elapsed: " << std::fixed << std::setprecision(2) << elapsed << "s | "
              << "Messages: " << messages << " | "
              << "Rate: " << std::fixed << std::setprecision(2) << msg_rate << " msg/s | "
              << "Throughput: " << std::fixed << std::setprecision(2) << (byte_rate / 1024.0) << " KB/s | "
              << "Errors: " << errors;

    if (!final) {
        std::cout << std::flush;
    } else {
        std::cout << std::endl;
    }
}

int run_test(const Config& config) {
    Stats stats;
    stats.start_time = std::chrono::steady_clock::now();

    int sock = connect_to_socket(config.socket_path);
    if (sock < 0) {
        return 1;
    }

    std::cout << "Connected to socket: " << config.socket_path << std::endl;
    std::cout << "Target rate: " << config.target_rate << " msg/s" << std::endl;
    std::cout << "Duration: " << config.duration << "s" << std::endl;
    std::cout << "Batch size: " << config.batch_size << std::endl;
    std::cout << "\nStarting test...\n" << std::endl;

    // Calculate sleep time between batches in microseconds
    auto batch_interval_us = std::chrono::microseconds(
        (config.batch_size * 1000000) / config.target_rate);

    auto test_start = std::chrono::steady_clock::now();
    auto next_batch_time = test_start;
    auto last_print_time = test_start;

    uint64_t counter = 0;

    while (running) {
        // Check if duration exceeded
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - test_start).count();
        if (elapsed >= config.duration) {
            break;
        }

        // Send a batch of messages
        for (int i = 0; i < config.batch_size && running; ++i) {
            std::string message = format_message(config.message_format, counter++);
            message += "\n";  // Add newline for syslog protocol

            ssize_t sent = send(sock, message.c_str(), message.length(), 0);
            if (sent < 0) {
                if (config.verbose) {
                    std::cerr << "\nError sending message: " << strerror(errno) << std::endl;
                }
                stats.errors++;

                // Try to reconnect
                close(sock);
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                sock = connect_to_socket(config.socket_path);
                if (sock < 0) {
                    std::cerr << "Failed to reconnect. Exiting." << std::endl;
                    return 1;
                }
            } else {
                stats.messages_sent++;
                stats.bytes_sent += sent;
            }
        }

        // Print stats every second
        now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::seconds>(now - last_print_time).count() >= 1) {
            print_stats(stats);
            last_print_time = now;
        }

        // Sleep until next batch
        next_batch_time += batch_interval_us;
        std::this_thread::sleep_until(next_batch_time);
    }

    print_stats(stats, true);
    close(sock);

    return 0;
}

int main(int argc, char* argv[]) {
    // Setup signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    std::string config_file = "injector_config.conf";

    if (argc > 1) {
        config_file = argv[1];
    }

    std::cout << "Fluent-Bit Syslog Injector" << std::endl;
    std::cout << "===========================" << std::endl;
    std::cout << "Loading configuration from: " << config_file << std::endl;

    Config config = load_config(config_file);

    return run_test(config);
}
