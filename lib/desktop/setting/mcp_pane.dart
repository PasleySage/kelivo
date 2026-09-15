import 'package:flutter/material.dart';

import '../../features/mcp/widgets/mcp_management_view.dart';
import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../core/providers/mcp_provider.dart';
import '../../shared/widgets/snackbar.dart';
import 'mcp_edit_dialog.dart' show showDesktopMcpEditDialog;
import '../../features/mcp/widgets/mcp_json_import.dart';
import '../../features/mcp/widgets/mcp_oauth_progress.dart';
import 'mcp_json_edit_dialog.dart' show showDesktopMcpJsonEditDialog;
import 'mcp_timeout_dialog.dart' show showDesktopMcpTimeoutDialog;
import '../../theme/app_font_weights.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';
import '../../utils/ui_scale.dart';

class DesktopMcpPane extends StatelessWidget {
  const DesktopMcpPane({super.key});

  @override
  Widget build(BuildContext context) =>
      const McpManagementView(desktop: true, embedded: true);
}
