import type { CSSProperties } from 'react'

interface BrandMarkProps {
  className?: string
}

export function BrandMark({ className = '' }: BrandMarkProps) {
  return (
    <span
      aria-hidden="true"
      className={`grid shrink-0 grid-cols-3 gap-[2px] rounded-[0.35rem] bg-black/25 p-[3px] shadow-[inset_0_0_0_1px_rgba(255,255,255,0.05)] ${className}`}
    >
      {Array.from({ length: 9 }, (_, index) => (
        <span
          className="aspect-square rounded-[2px] bg-current opacity-[var(--pad-opacity)] shadow-[0_0_5px_currentColor]"
          key={index}
          style={{ '--pad-opacity': 0.42 + (index % 3) * 0.18 } as CSSProperties}
        />
      ))}
    </span>
  )
}
