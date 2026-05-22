<?php // #ddev-generated
/**
 * extract-secrets.php
 *
 * PHP-based secret extractor for Drupal settings*.php files.
 * Runs inside the DDEV web container via:
 *   ddev exec php /var/www/html/.ddev/secret-vault/extract-secrets.php \
 *       /var/www/html/web/sites/default/settings.local.php [--skip-hash-salt]
 *
 * Outputs a JSON object of discovered secrets to stdout.
 */

$skip_hash_salt = false;
$file = null;

foreach (array_slice($argv, 1) as $arg) {
    if ($arg === '--skip-hash-salt') {
        $skip_hash_salt = true;
    } elseif ($file === null) {
        $file = $arg;
    }
}

if (empty($file)) {
    fwrite(STDERR, "Usage: extract-secrets.php <path-to-settings.local.php> [--skip-hash-salt]\n");
    exit(1);
}

if (!file_exists($file)) {
    fwrite(STDERR, "File not found: {$file}\n");
    exit(1);
}

// -------------------------------------------------------------------------
// Capture variables defined by settings.local.php in a controlled scope
// -------------------------------------------------------------------------
$settings  = [];
$databases = [];
$config    = [];

// Include the file — variables will populate the local scope
(function () use ($file, &$settings, &$databases, &$config) {
    include $file;
})();

// -------------------------------------------------------------------------
// Extract known secrets
// -------------------------------------------------------------------------
$secrets = [];

// Drupal hash salt
if (!$skip_hash_salt && !empty($settings['hash_salt'])) {
    $secrets['DRUPAL_HASH_SALT'] = (string) $settings['hash_salt'];
}

// Database password(s)
foreach ($databases as $db_key => $targets) {
    foreach ($targets as $target_key => $db_info) {
        if (!empty($db_info['password'])) {
            $env_key = strtoupper("DB_PASSWORD_{$db_key}_{$target_key}");
            // Use DB_PASSWORD for the default/default connection
            if ($db_key === 'default' && $target_key === 'default') {
                $env_key = 'DB_PASSWORD';
            }
            $secrets[$env_key] = (string) $db_info['password'];
        }
        if (!empty($db_info['username']) && $db_info['username'] !== 'db') {
            $env_key = strtoupper("DB_USER_{$db_key}_{$target_key}");
            if ($db_key === 'default' && $target_key === 'default') {
                $env_key = 'DB_USER';
            }
            $secrets[$env_key] = (string) $db_info['username'];
        }
    }
}

// Known sensitive $settings keys
$sensitive_settings_keys = [
    'mail_system'        => false,  // not sensitive
    'smtp_password'      => 'SMTP_PASSWORD',
    'smtp_username'      => 'SMTP_USERNAME',
    'sendgrid_api_key'   => 'SENDGRID_API_KEY',
    'mailgun_api_key'    => 'MAILGUN_API_KEY',
    'stripe_secret_key'  => 'STRIPE_SECRET_KEY',
    'stripe_public_key'  => 'STRIPE_PUBLIC_KEY',
    'google_maps_api_key'=> 'GOOGLE_MAPS_API_KEY',
    'recaptcha_private_key' => 'RECAPTCHA_PRIVATE_KEY',
    'recaptcha_public_key'  => 'RECAPTCHA_PUBLIC_KEY',
    'jwt_secret'         => 'JWT_SECRET',
];

foreach ($sensitive_settings_keys as $settings_key => $env_key) {
    if ($env_key && !empty($settings[$settings_key])) {
        $secrets[$env_key] = (string) $settings[$settings_key];
    }
}

// Auto-detect other sensitive-looking $settings keys
$sensitive_patterns = [
    '/api[_\-]?key/i',
    '/api[_\-]?token/i',
    '/secret[_\-]?key/i',
    '/auth[_\-]?token/i',
    '/access[_\-]?token/i',
    '/private[_\-]?key/i',
    '/[_\-]key/i',
    '/[_\-]token/i',
    '/password/i',
    '/passwd/i',
    '/passphrase/i',
    '/credentials/i',
];

foreach ($settings as $key => $value) {
    if (!is_string($value) || empty($value)) {
        continue;
    }
    foreach ($sensitive_patterns as $pattern) {
        if (preg_match($pattern, (string) $key)) {
            // Convert settings key to ENV_KEY format
            $env_key = strtoupper(preg_replace('/[^A-Z0-9]/i', '_', $key));
            if (!isset($secrets[$env_key])) {
                $secrets[$env_key] = $value;
            }
            break;
        }
    }
}

// Config overrides with sensitive keys
foreach ($config as $config_key => $config_values) {
    if (!is_array($config_values)) {
        continue;
    }
    foreach ($config_values as $key => $value) {
        if (!is_string($value) || empty($value)) {
            continue;
        }
        foreach ($sensitive_patterns as $pattern) {
            if (preg_match($pattern, (string) $key)) {
                $env_key = strtoupper(preg_replace('/[^A-Z0-9]/i', '_', $config_key . '_' . $key));
                if (!isset($secrets[$env_key])) {
                    $secrets[$env_key] = $value;
                }
                break;
            }
        }
    }
}

// -------------------------------------------------------------------------
// Output as JSON
// -------------------------------------------------------------------------
echo json_encode($secrets, JSON_PRETTY_PRINT) . "\n";
