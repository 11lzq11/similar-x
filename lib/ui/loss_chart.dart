// Live LOSS vs Step chart (CustomPainter). Shows the most recent points
// on a log-ish scale (loss is plotted on a linear axis but the range adapts
// to the data so a drop from 7 to 3 is clearly visible).
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

class LossChart extends StatelessWidget {
  final List<(int, double)> points;

  const LossChart({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _LossChartPainter(points),
      size: const Size(double.infinity, 160),
    );
  }
}

class _LossChartPainter extends CustomPainter {
  final List<(int, double)> points;

  _LossChartPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = Colors.grey.shade100;
    canvas.drawRect(Offset.zero & size, bg);

    final gridPaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (points.length < 2) {
      final tp = TextPainter(
        text: const TextSpan(
          text: '开始训练后这里会显示 LOSS 曲线',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
      );
      return;
    }

    final losses = points.map((p) => p.$2).where((v) => v.isFinite).toList();
    if (losses.isEmpty) return;
    var minLoss = losses.reduce(math.min);
    var maxLoss = losses.reduce(math.max);
    if ((maxLoss - minLoss).abs() < 0.1) {
      maxLoss = minLoss + 0.1;
    }
    // Pad the range a little so the line never touches the edge.
    final pad = (maxLoss - minLoss) * 0.1;
    minLoss -= pad;
    maxLoss += pad;

    final firstStep = points.first.$1;
    final lastStep = points.last.$1;
    final stepRange = math.max(1, lastStep - firstStep);

    final linePaint = Paint()
      ..color = Colors.indigo
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final (step, loss) = points[i];
      if (!loss.isFinite) continue;
      final x = size.width * (step - firstStep) / stepRange;
      final y = size.height * (1 - (loss - minLoss) / (maxLoss - minLoss));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);

    // Latest value label.
    final last = points.last;
    final label = 'Step ${last.$1}  LOSS ${last.$2.toStringAsFixed(3)}';
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.indigo,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(8, 8));
  }

  @override
  bool shouldRepaint(_LossChartPainter oldDelegate) =>
      oldDelegate.points != points;
}
