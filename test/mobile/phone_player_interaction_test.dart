import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/phone/phone_player_interaction.dart';

void main() {
  testWidgets('lock requires a visible explicit unlock and survives timeout', (
    tester,
  ) async {
    final interaction = PhonePlayerInteraction();
    addTearDown(interaction.dispose);
    interaction.lock();
    expect(interaction.locked, isTrue);
    expect(interaction.unlockVisible, isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(interaction.locked, isTrue);
    expect(interaction.unlockVisible, isFalse);
    interaction.unlock();
    expect(interaction.locked, isTrue);
    interaction.revealUnlock();
    expect(interaction.unlockVisible, isTrue);
    interaction.unlock();
    expect(interaction.locked, isFalse);
  });

  testWidgets('overlapping controls stay occupied until each releases', (
    tester,
  ) async {
    final interaction = PhonePlayerInteraction();
    addTearDown(interaction.dispose);
    final releaseSeek = interaction.occupy();
    final releasePanel = interaction.occupy();
    expect(interaction.occupied, isTrue);
    releaseSeek();
    expect(interaction.occupied, isTrue);
    releasePanel();
    expect(interaction.occupied, isFalse);
  });
}
