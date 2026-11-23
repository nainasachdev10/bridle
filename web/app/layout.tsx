import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";

export const metadata: Metadata = {
  title: "Bridle",
  description: "Curated Uniswap v4 liquidity under enforceable mandates, scored against simply holding.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <header>
          <Link href="/" className="brand">Bridle</Link>
          <span className="muted">Unichain Sepolia testnet</span>
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
