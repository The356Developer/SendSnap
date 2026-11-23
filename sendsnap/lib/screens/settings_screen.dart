import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/device_provider.dart';
import '../providers/locale_provider.dart';
import '../l10n/app_localizations.dart';
import '../config/constants.dart';
import '../services/rating_service.dart';
import '../services/tray_and_window_service.dart';
import '../services/file_handler.dart';
import '../services/ecosystem_service.dart';
import '../widgets/glass_container.dart';
import '../widgets/bouncing_card.dart';
import '../widgets/ambient_background.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _controller;
  bool _autostartEnabled = false;
  bool _isPagelitInstalled = false;

  @override
  void initState() {
    super.initState();
    final devProv = Provider.of<DeviceProvider>(context, listen: false);
    _controller = TextEditingController(text: devProv.displayName);

    if (TrayAndWindowService.isDesktop) {
      EcosystemService.isPagelitInstalled().then((installed) {
        if (mounted) setState(() => _isPagelitInstalled = installed);
      });

      TrayAndWindowService.instance.isAutostartEnabled().then((enabled) {
        if (mounted) setState(() => _autostartEnabled = enabled);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devProv = Provider.of<DeviceProvider>(context);
    final localeProv = Provider.of<LocaleProvider>(context);
    final l10n = AppLocalizations.of(context)!;
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                children: [
                  _buildHeader(context, l10n, isRtl),
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.l, vertical: AppSpacing.m),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Device Display Name
                          GlassContainer(
                            blur: 25,
                            opacity: 0.75,
                            borderRadius: 28,
                            padding: const EdgeInsets.all(22),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.settingsDeviceName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.primary,
                                    fontSize: 11,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _controller,
                                  decoration: InputDecoration(
                                    hintText: l10n.settingsDeviceNameHint,
                                    hintStyle: TextStyle(color: AppColors.textSecondaryOf(context)),
                                    filled: true,
                                    fillColor: AppColors.subtleFillOf(context),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(16),
                                      borderSide: BorderSide.none,
                                    ),
                                    prefixIcon: Icon(
                                      Icons.devices_rounded,
                                      size: 20,
                                      color: AppColors.textSecondaryOf(context),
                                    ),
                                  ),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimaryOf(context),
                                  ),
                                  onChanged: (val) => devProv.updateDisplayName(val),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Dark Mode Appearance Card
                          GlassContainer(
                            blur: 20,
                            opacity: 0.75,
                            borderRadius: 24,
                            padding: const EdgeInsets.all(18),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppColors.primary.withValues(alpha: 0.12),
                                  ),
                                  child: Icon(
                                    localeProv.isDarkMode
                                        ? Icons.dark_mode_rounded
                                        : Icons.light_mode_rounded,
                                    color: AppColors.primary,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Dark Mode',
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          color: Theme.of(context).brightness == Brightness.dark
                                              ? Colors.white
                                              : AppColors.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        localeProv.isDarkMode
                                            ? 'Dark theme enabled'
                                            : 'Switch between light and dark theme',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textSecondaryOf(context),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch.adaptive(
                                  value: localeProv.isDarkMode,
                                  activeTrackColor: AppColors.primary,
                                  onChanged: (val) => localeProv.toggleDarkMode(val),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),

                          // App Language Selection
                          GlassContainer(
                            blur: 20,
                            opacity: 0.75,
                            borderRadius: 24,
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: AppColors.primary.withValues(alpha: 0.12),
                                      ),
                                      child: const Icon(Icons.language_rounded, color: AppColors.primary, size: 18),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      l10n.settingsLanguage,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.primary,
                                        fontSize: 11,
                                        letterSpacing: 1.0,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: LocaleProvider.supportedLanguages.map((option) {
                                    final isSelected = localeProv.currentCode == option.code;
                                    return BouncingCard(
                                      onTap: () => localeProv.setLanguage(option.code),
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 200),
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? AppColors.primary
                                              : AppColors.subtleFillOf(context),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(
                                            color: isSelected
                                                ? AppColors.primary
                                                : AppColors.subtleBorderOf(context),
                                            width: 1.2,
                                          ),
                                          boxShadow: isSelected
                                              ? [
                                                  BoxShadow(
                                                    color: AppColors.primary.withValues(alpha: 0.28),
                                                    blurRadius: 10,
                                                    offset: const Offset(0, 3),
                                                  ),
                                                ]
                                              : [],
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (isSelected) ...[
                                              const Icon(Icons.check_rounded, size: 14, color: Colors.white),
                                              const SizedBox(width: 6),
                                            ],
                                            Text(
                                              option.code == 'system' ? l10n.settingsLanguageSystem : option.nativeName,
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                                                color: isSelected ? Colors.white : AppColors.textPrimaryOf(context),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Storage & Downloads Folder
                          GlassContainer(
                            blur: 20,
                            opacity: 0.75,
                            borderRadius: 24,
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.settingsStorageTitle,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.primary,
                                    fontSize: 11,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: AppColors.primary.withValues(alpha: 0.12),
                                      ),
                                      child: const Icon(Icons.folder_rounded, color: AppColors.primary, size: 20),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            l10n.settingsSendSnapFolder,
                                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimaryOf(context)),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            'Downloads/SendSnap',
                                            style: TextStyle(fontSize: 11, color: AppColors.textSecondaryOf(context)),
                                          ),
                                        ],
                                      ),
                                    ),
                                    BouncingCard(
                                      onTap: () => FileHandler.openFolderChoice(context),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                        decoration: BoxDecoration(
                                          gradient: AppColors.primaryGradient,
                                          borderRadius: BorderRadius.circular(14),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.folder_open_rounded, size: 14, color: Colors.white),
                                            const SizedBox(width: 6),
                                            Text(
                                              l10n.settingsOpen,
                                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Desktop & Startup Settings (Windows / macOS / Linux)
                          if (TrayAndWindowService.isDesktop) ...[
                            GlassContainer(
                              blur: 20,
                              opacity: 0.75,
                              borderRadius: 24,
                              padding: const EdgeInsets.all(18),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.settingsWindowsSettings,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.primary,
                                      fontSize: 11,
                                      letterSpacing: 1.0,
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: AppColors.primary.withValues(alpha: 0.12),
                                        ),
                                        child: const Icon(Icons.power_settings_new_rounded, color: AppColors.primary, size: 20),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              l10n.settingsLaunchStartup,
                                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimaryOf(context)),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              l10n.settingsLaunchStartupDesc,
                                              style: TextStyle(fontSize: 11, color: AppColors.textSecondaryOf(context)),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Switch.adaptive(
                                        value: _autostartEnabled,
                                        activeTrackColor: AppColors.primary,
                                        onChanged: (val) async {
                                          final success = await TrayAndWindowService.instance.setAutostart(val);
                                          if (mounted && success) {
                                            setState(() => _autostartEnabled = val);
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    child: Divider(height: 1),
                                  ),
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: AppColors.success.withValues(alpha: 0.12),
                                        ),
                                        child: const Icon(Icons.density_medium_rounded, color: AppColors.success, size: 20),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              l10n.settingsTaskbarTray,
                                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimaryOf(context)),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              l10n.settingsTaskbarTrayDesc,
                                              style: TextStyle(fontSize: 11, color: AppColors.textSecondaryOf(context)),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: AppColors.success.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          l10n.settingsTrayEnabled,
                                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: AppColors.success),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],

                          _buildEcosystemCard(context),
                          const SizedBox(height: 16),

                          BouncingCard(
                            onTap: () => RatingService.showManual(context),
                            child: GlassContainer(
                              blur: 20,
                              opacity: 0.75,
                              borderRadius: 22,
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: const LinearGradient(
                                        colors: [Color(0xFFFFD700), Color(0xFFFF9500)],
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFFFF9500).withValues(alpha: 0.35),
                                          blurRadius: 10,
                                          offset: const Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(Icons.star_rounded, color: Colors.white, size: 20),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          l10n.settingsRateApp,
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.textPrimaryOf(context),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          l10n.settingsRateAppDesc,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w500,
                                            color: AppColors.textSecondaryOf(context),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Transform.flip(
                                    flipX: isRtl,
                                    child: Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textSecondaryOf(context)),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),

                          if (!TrayAndWindowService.isDesktop) ...[
                            BouncingCard(
                              onTap: () async {
                                final uri = Uri.parse(AppConstants.websiteUrl);
                                try {
                                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                                } catch (_) {}
                              },
                              child: GlassContainer(
                                blur: 20,
                                opacity: 0.75,
                                borderRadius: 22,
                                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: const LinearGradient(
                                          colors: [Color(0xFF007AFF), Color(0xFF00C7BE)],
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: const Color(0xFF007AFF).withValues(alpha: 0.35),
                                            blurRadius: 10,
                                            offset: const Offset(0, 3),
                                          ),
                                        ],
                                      ),
                                      child: const Icon(Icons.laptop_chromebook_rounded, color: Colors.white, size: 20),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            l10n.settingsGetDesktop.replaceAll(' / Mac', '').replaceAll('/Mac', ''),
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.textPrimaryOf(context),
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            l10n.settingsGetDesktopDesc.replaceAll(', Mac,', ' and').replaceAll(' / Mac', ''),
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w500,
                                              color: AppColors.textSecondaryOf(context),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.open_in_new_rounded, size: 16, color: AppColors.textSecondaryOf(context)),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],

                          const SizedBox(height: 28),
                          Center(
                            child: Text(
                              'SendSnap v2.2.10',
                              style: TextStyle(
                                color: AppColors.textSecondaryOf(context),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppLocalizations l10n, bool isRtl) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          BouncingCard(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surfaceOf(context),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.inkOf(context), width: 1.6),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.isDark(context)
                        ? Colors.black.withValues(alpha: 0.7)
                        : AppColors.ink,
                    blurRadius: 0,
                    offset: const Offset(2, 2.5),
                  ),
                ],
              ),
              child: Transform.flip(
                flipX: isRtl,
                child: Icon(Icons.arrow_back_rounded, size: 20, color: AppColors.textPrimaryOf(context)),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              l10n.settingsTitle,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                color: AppColors.textPrimaryOf(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEcosystemCard(BuildContext context) {
    return GlassContainer(
      blur: 20,
      opacity: 0.75,
      borderRadius: 24,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'THE 356 COMPANY ECOSYSTEM',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                  fontSize: 11,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'COMPANION APP',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF6B6B), Color(0xFFFF8E53)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFF6B6B).withValues(alpha: 0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(Icons.auto_stories_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Pagelit',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimaryOf(context)),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'PDF & Office',
                          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: AppColors.textSecondaryOf(context)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Distraction-free viewer & reader for PDF, Word, PowerPoint & Excel documents received via SendSnap.',
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondaryOf(context), height: 1.3),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          BouncingCard(
            onTap: () => EcosystemService.openPagelitStore(),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF6B6B), Color(0xFFFF8E53)],
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF6B6B).withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isPagelitInstalled ? Icons.check_circle_rounded : Icons.download_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isPagelitInstalled ? 'Installed • View on Google Play' : 'Get Pagelit on Google Play',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
