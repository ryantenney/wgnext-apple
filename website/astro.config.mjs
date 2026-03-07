import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://wgnext.app',
  integrations: [
    starlight({
      title: 'WGnext',
      description: 'WireGuard VPN client for iOS and macOS with automatic tunnel failover.',
      logo: {
        light: './src/assets/logo-light.svg',
        dark: './src/assets/logo-dark.svg',
        replacesTitle: true,
      },
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/rtenney/wgnext' },
      ],
      customCss: ['./src/styles/custom.css'],
      head: [
        {
          tag: 'meta',
          attrs: { property: 'og:image', content: 'https://wgnext.app/og-image.png' },
        },
      ],
      sidebar: [
        {
          label: 'Getting Started',
          items: [
            { label: 'What is WGnext?', link: '/guides/introduction/' },
            { label: 'Installation', link: '/guides/installation/' },
            { label: 'Quick Start', link: '/guides/quick-start/' },
          ],
        },
        {
          label: 'Features',
          items: [
            { label: 'Tunnel Management', link: '/features/tunnel-management/' },
            { label: 'Failover Groups', link: '/features/failover-groups/' },
            { label: 'On-Demand Activation', link: '/features/on-demand/' },
            { label: 'Import & Export', link: '/features/import-export/' },
          ],
        },
        {
          label: 'Failover Deep Dive',
          items: [
            { label: 'How Failover Works', link: '/failover/how-it-works/' },
            { label: 'Health Detection', link: '/failover/health-detection/' },
            { label: 'Configuration', link: '/failover/configuration/' },
            { label: 'Troubleshooting', link: '/failover/troubleshooting/' },
          ],
        },
        {
          label: 'Building from Source',
          items: [
            { label: 'Prerequisites', link: '/development/prerequisites/' },
            { label: 'Build & Run', link: '/development/build/' },
            { label: 'Contributing', link: '/development/contributing/' },
          ],
        },
      ],
    }),
  ],
});
