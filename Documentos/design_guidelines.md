# SIG-Microbuses - Design Guidelines

## 1. Core Philosophy
The SIG-Microbuses app embraces a modern, clean, and highly dynamic aesthetic. The core visual language utilizes a "Glassmorphism" approach combined with a vibrant Purple and White color scheme to reflect both technology and approachability. Components should avoid looking generic (i.e., default Material Design out-of-the-box), striving instead for custom, organic, and sleek shapes.

## 2. Color Palette

*   **Primary Purple**: `#7033FF` (Vibrant, modern purple used for main branding, key buttons, and active states).
*   **Secondary/Deep Purple**: `#4A148C` (Used for gradients, deep shadows, and high-contrast text).
*   **Accent Light Purple**: `#E1BEE7` (Used for subtle highlights, inactive states, and soft backgrounds).
*   **Primary White**: `#FFFFFF` (Used for high-contrast text on purple backgrounds, and core component bases).
*   **Off-White Background**: `#F4F5F9` (Used for the main app background where maps are not present).
*   **Glassmorphism Base**: `rgba(255, 255, 255, 0.25)` or `Colors.white.withOpacity(0.25)` in Flutter.

## 3. Typography
*   **Primary Font Family**: *Poppins* or *Montserrat* (Geometric, highly legible, modern).
*   **Headings (H1, H2, H3)**: Bold (700) or Semi-Bold (600). Color: Deep Purple `#4A148C`.
*   **Body Text**: Regular (400) or Medium (500). Color: Dark Grey `#333333` on light backgrounds, or `#FFFFFF` on dark backgrounds.
*   **Microcopy / Labels**: Medium (500), 12px. Color: `#757575`.

## 4. Glassmorphism Styling Rules (Flutter)
To achieve the frosted glass effect for overlay cards (e.g., passenger map view overlays, routing details):
1.  **Blur Effect**: Use `BackdropFilter` with `ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0)`.
2.  **Container Color**: Use a white with low opacity, e.g., `Colors.white.withOpacity(0.2)`.
3.  **Border**: Apply a subtle semi-transparent white border to simulate the glass edge: `Border.all(color: Colors.white.withOpacity(0.4), width: 1.5)`.
4.  **Shadows**: Add a soft drop shadow beneath the glass component to lift it off the background: `BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 20, spreadRadius: -5)`.
5.  **Border Radius**: Use rounded, friendly corners: `BorderRadius.circular(24.0)`.

## 5. UI Components & Elements
*   **Buttons**: Avoid sharp rectangles. Use fully rounded corners (`StadiumBorder` or `BorderRadius.circular(30)`). Use a horizontal gradient from Primary Purple to Deep Purple for primary calls-to-action.
*   **Map Markers**: Custom SVG markers representing the microbuses. Do not use default Google Maps pins. The microbus markers should be purple with white accents, preferably with a subtle glowing aura (`BoxShadow`) to show active tracking.
*   **Bottom Navigation**: A floating, glassmorphic pill-shaped navigation bar, rather than a full-width block attached to the bottom edge.

## 6. Micro-Interactions
*   **Tap Feedback**: Subtle scaling (shrink by 5%) on tap down, returning to normal on release.
*   **Loading States**: Replace standard circular progress indicators with custom animations (e.g., a pulsating purple microbus logo or an infinite gradient sweep on a placeholder).
