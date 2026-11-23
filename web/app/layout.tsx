import type { Metadata } from "next";
import { Archivo, IBM_Plex_Mono } from "next/font/google";
import Link from "next/link";
import { Logo } from "@/components/Art";
import { Nav } from "@/components/Nav";
import { EXPLORER, HOOK } from "@/lib/chain";
import "./globals.css";

const archivo = Archivo({ subsets: ["latin"], axes: ["wdth"], variable: "--font-sans" });
const plexMono = IBM_Plex_Mono({ subsets: ["latin"], weight: ["400", "500"], variable: "--font-mono" });

const REPO = "https://github.com/nainasachdev10/bridle";

export const metadata: Metadata = {
  title: "Bridle: liquidity on a short rein",
  description: "Uniswap v4 vaults run by curators under enforceable mandates, scored against simply holding.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${archivo.variable} ${plexMono.variable}`}>
      <body>
        <div className="wrap top-bar">
          <header className="top">
            <Link href="/" className="brand" aria-label="Bridle home">
              <Logo height={34} />
            </Link>
            <Nav />
            <a className="btn btn-line btn-sm" href={REPO}>Source on GitHub</a>
          </header>
        </div>
        <main>{children}</main>
        <footer className="foot">
          <div className="wrap foot-in">
            <div>
              <Logo height={36} />
              <p>Uniswap v4 liquidity managed by curators who can only move it inside rules they signed, and an exit that never closes.</p>
            </div>
            <div>
              <h4 className="display">Explore</h4>
              <nav>
                <Link href="/#vaults">Vaults</Link>
                <Link href="/#how">How it works</Link>
                <Link href="/#scoring">Scoring</Link>
              </nav>
            </div>
            <div>
              <h4 className="display">On chain</h4>
              <nav>
                <a href={`${EXPLORER}/address/${HOOK}`}>Hook contract</a>
                <a href={REPO}>Source code</a>
                <span className="muted">Unichain Sepolia testnet</span>
              </nav>
            </div>
          </div>
        </footer>
      </body>
    </html>
  );
}
