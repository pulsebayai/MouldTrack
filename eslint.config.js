// https://docs.expo.dev/guides/using-eslint/
const { defineConfig } = require('eslint/config');
const expoConfig = require('eslint-config-expo/flat');

module.exports = defineConfig([
  expoConfig,
  {
    ignores: ['dist/*', 'android/*', 'node_modules/*', 'playwright-report/*', 'test-results/*', 'supabase/.temp/*', 'supabase/functions/user-admin/*', 'supabase/functions/account/*', 'supabase/functions/_shared/{http,clients,errors}.ts'],
  },
]);
