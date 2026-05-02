#pragma once

#include <cpp-httplib/httplib.h>
#include <cstdlib>
#include <sys/stat.h>

struct common_http_url {
    std::string scheme;
    std::string user;
    std::string password;
    std::string host;
    int port;
    std::string path;
};

static common_http_url common_http_parse_url(const std::string & url) {
    common_http_url parts;
    auto scheme_end = url.find("://");

    if (scheme_end == std::string::npos) {
        throw std::runtime_error("invalid URL: no scheme");
    }
    parts.scheme = url.substr(0, scheme_end);

    if (parts.scheme != "http" && parts.scheme != "https") {
        throw std::runtime_error("unsupported URL scheme: " + parts.scheme);
    }

    auto rest = url.substr(scheme_end + 3);
    auto at_pos = rest.find('@');

    if (at_pos != std::string::npos) {
        auto auth = rest.substr(0, at_pos);
        auto colon_pos = auth.find(':');
        if (colon_pos != std::string::npos) {
            parts.user = auth.substr(0, colon_pos);
            parts.password = auth.substr(colon_pos + 1);
        } else {
            parts.user = auth;
        }
        rest = rest.substr(at_pos + 1);
    }

    auto slash_pos = rest.find('/');

    if (slash_pos != std::string::npos) {
        parts.host = rest.substr(0, slash_pos);
        parts.path = rest.substr(slash_pos);
    } else {
        parts.host = rest;
        parts.path = "/";
    }

    auto colon_pos = parts.host.find(':');

    if (colon_pos != std::string::npos) {
        parts.port = std::stoi(parts.host.substr(colon_pos + 1));
        parts.host = parts.host.substr(0, colon_pos);
    } else if (parts.scheme == "http") {
        parts.port = 80;
    } else if (parts.scheme == "https") {
        parts.port = 443;
    } else {
        throw std::runtime_error("unsupported URL scheme: " + parts.scheme);
    }

    return parts;
}

static std::pair<httplib::Client, common_http_url> common_http_client(const std::string & url) {
    common_http_url parts = common_http_parse_url(url);

    if (parts.host.empty()) {
        throw std::runtime_error("error: invalid URL format");
    }

#ifndef CPPHTTPLIB_OPENSSL_SUPPORT
    if (parts.scheme == "https") {
        throw std::runtime_error(
            "HTTPS is not supported. Please rebuild with one of:\n"
            "  -DLLAMA_BUILD_BORINGSSL=ON\n"
            "  -DLLAMA_BUILD_LIBRESSL=ON\n"
            "  -DLLAMA_OPENSSL=ON (default, requires OpenSSL dev files installed)"
        );
    }
#endif

    httplib::Client cli(parts.scheme + "://" + parts.host + ":" + std::to_string(parts.port));

#ifdef CPPHTTPLIB_OPENSSL_SUPPORT
    // When llama.cpp is linked against a freshly-built BoringSSL/LibreSSL
    // (LLAMA_BUILD_BORINGSSL / LLAMA_BUILD_LIBRESSL), SSL_CTX_set_default_verify_paths()
    // does not always pick up the system CA bundle nor the SSL_CERT_FILE/SSL_CERT_DIR
    // env vars (its compiled-in OPENSSLDIR points to a path that does not exist on
    // Linux distros). Explicitly load a CA bundle if one is available.
    if (parts.scheme == "https") {
        struct stat st;
        const char * env_file = std::getenv("SSL_CERT_FILE");
        const char * env_dir  = std::getenv("SSL_CERT_DIR");
        if (env_file && *env_file && stat(env_file, &st) == 0) {
            cli.set_ca_cert_path(env_file, env_dir && *env_dir ? env_dir : "");
        } else {
            // Common locations on Debian/Ubuntu, Fedora/RHEL, Arch.
            static const char * candidates[] = {
                "/etc/ssl/certs/ca-certificates.crt",
                "/etc/pki/tls/certs/ca-bundle.crt",
                "/etc/ssl/cert.pem",
                nullptr,
            };
            for (const char ** p = candidates; *p; ++p) {
                if (stat(*p, &st) == 0) {
                    cli.set_ca_cert_path(*p, "");
                    break;
                }
            }
        }
    }
#endif

    if (!parts.user.empty()) {
        cli.set_basic_auth(parts.user, parts.password);
    }

    cli.set_follow_location(true);

    return { std::move(cli), std::move(parts) };
}

static std::string common_http_show_masked_url(const common_http_url & parts) {
    return parts.scheme + "://" + (parts.user.empty() ? "" : "****:****@") + parts.host + parts.path;
}
