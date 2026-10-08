//
//  InitialFollowsStepView.swift
//  HavenApp
//
//  Initial follows step for new user onboarding
//

import SwiftUI

struct InitialFollowsStepView: View {
    /// Picks from an earlier visit to this step, so Back and forward keeps them.
    var initiallySelected: Set<String> = []
    let onContinue: ([String]) -> Void
    let onSkip: () -> Void

    @State private var packsData: StarterPacksData?
    // Packs start open: people hidden behind a chevron were people nobody saw.
    @State private var collapsedPackIds: Set<String> = []
    @State private var selectedNpubs: Set<String> = []
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 20)

            // Header
            VStack(spacing: 8) {
                Text("Find People to Follow")
                    .font(.appSystem(size: 24, weight: .bold))
                    .foregroundColor(WizardColors.textPrimary)

                Text("Pick a few to fill your feed. You can follow more anytime.")
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            ScrollView {
                VStack(spacing: 12) {
                    if let packs = packsData?.packs {
                        ForEach(packs) { pack in
                            PackCard(
                                pack: pack,
                                isExpanded: !collapsedPackIds.contains(pack.id),
                                selectedNpubs: $selectedNpubs,
                                onToggleExpand: {
                                    withAnimation(Motion.pop) {
                                        if collapsedPackIds.contains(pack.id) {
                                            collapsedPackIds.remove(pack.id)
                                        } else {
                                            collapsedPackIds.insert(pack.id)
                                        }
                                    }
                                }
                            )
                        }
                    } else {
                        Text("No packs available")
                            .foregroundColor(WizardColors.textMuted)
                    }
                }
                .padding(.vertical, 8)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(WizardAnimations.springEnter.delay(0.2), value: appeared)

            // Selected count badge
            if !selectedNpubs.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.appSystem(size: 16))
                        .foregroundColor(WizardColors.accentPrimary)
                    Text("\(selectedNpubs.count) account\(selectedNpubs.count == 1 ? "" : "s") selected")
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(WizardColors.bgCard)
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(WizardColors.borderActive, lineWidth: 1)
                )
                .transition(.scale.combined(with: .opacity))
            }

            // Buttons
            VStack(spacing: 12) {
                WizardPrimaryButton(
                    title: selectedNpubs.isEmpty ? "Skip for Now" : "Follow \(selectedNpubs.count)",
                    action: {
                        if selectedNpubs.isEmpty {
                            onSkip()
                        } else {
                            onContinue(Array(selectedNpubs))
                        }
                    }
                )

                if !selectedNpubs.isEmpty {
                    Button(action: onSkip) {
                        Text("Skip and don't follow")
                            .font(.appSystem(size: 14))
                            .foregroundColor(WizardColors.textMuted)
                    }
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(WizardAnimations.springEnter.delay(0.3), value: appeared)

            Spacer()
        }
        .onAppear {
            appeared = true
            packsData = StarterPacksData.load()?.validated()
            if selectedNpubs.isEmpty { selectedNpubs = initiallySelected }
        }
    }
}

private struct PackCard: View {
    let pack: StarterPack
    let isExpanded: Bool
    @Binding var selectedNpubs: Set<String>
    let onToggleExpand: () -> Void

    var body: some View {
        WizardGlassCard(isSelected: false) {
            VStack(alignment: .leading, spacing: 12) {
                // Pack header
                Button(action: onToggleExpand) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pack.name)
                                .font(.appSystem(size: 17, weight: .semibold))
                                .foregroundColor(WizardColors.textPrimary)

                            Text(pack.description)
                                .font(.appSystem(size: 13))
                                .foregroundColor(WizardColors.textSecondary)
                                .lineSpacing(2)
                        }

                        Spacer()

                        VStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.appSystem(size: 14, weight: .medium))
                                .foregroundColor(WizardColors.accentPrimary)

                            Text("\(pack.accounts.count)")
                                .font(.appSystem(size: 11))
                                .foregroundColor(WizardColors.textMuted)
                        }
                    }
                }
                .buttonStyle(.plain)

                // Expanded accounts list
                if isExpanded {
                    VStack(spacing: 8) {
                        ForEach(pack.accounts) { account in
                            AccountRow(
                                account: account,
                                isSelected: selectedNpubs.contains(account.npub),
                                onToggle: {
                                    withAnimation(Motion.pop) {
                                        if selectedNpubs.contains(account.npub) {
                                            selectedNpubs.remove(account.npub)
                                        } else {
                                            selectedNpubs.insert(account.npub)
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

private struct AccountRow: View {
    let account: RecommendedAccount
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Checkbox
                ZStack {
                    Circle()
                        .fill(isSelected ? WizardColors.accentPrimary : WizardColors.bgElevated)
                        .frame(width: 24, height: 24)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.appSystem(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        // borderSubtle is #27272A and so is bgElevated, which is
                        // this row's background — an unselected checkbox drawn
                        // in it has 1:1 contrast and is invisible. Nothing then
                        // tells you the row can be selected at all, and you only
                        // learn it by tapping. textMuted is 3.08:1 against the
                        // row, which is the WCAG 1.4.11 floor for a control
                        // boundary.
                        Circle()
                            .stroke(WizardColors.textMuted, lineWidth: 2)
                            .frame(width: 24, height: 24)
                    }
                }

                AvatarView(
                    url: URL(string: account.picture),
                    pubkey: NpubValidation.hexPubkey(fromNpub: account.npub) ?? "",
                    size: 36
                )

                // Account info
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)

                    Text(account.about)
                        .font(.appSystem(size: 12))
                        .foregroundColor(WizardColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(10)
            .background(isSelected ? WizardColors.bgCard : WizardColors.bgElevated)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? WizardColors.borderActive : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
