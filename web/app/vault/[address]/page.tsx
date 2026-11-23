import { VAULTS } from "@/lib/chain";
import { VaultView } from "@/components/VaultView";

export function generateStaticParams() {
  return VAULTS.map((v) => ({ address: v.address }));
}

export default async function VaultPage({ params }: { params: Promise<{ address: string }> }) {
  const { address } = await params;
  const vault = VAULTS.find((v) => v.address === address);
  if (!vault) return <p className="wrap">Unknown vault.</p>;
  return <VaultView address={vault.address} />;
}
