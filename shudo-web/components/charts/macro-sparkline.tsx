'use client'

import { Area, AreaChart, ResponsiveContainer, XAxis, YAxis } from 'recharts'
import { DayTotals } from '@/types/database'
import { format, parseISO } from 'date-fns'

interface MacroSparklineProps {
  data: DayTotals[]
  dataKey: 'total_calories' | 'total_protein' | 'total_carbs' | 'total_fat'
  color: string
  target?: number
  unit?: string
}

export function MacroSparkline({ data, dataKey, color, target, unit = '' }: MacroSparklineProps) {
  const chartData = data.map((d) => ({
    ...d,
    date: format(parseISO(d.local_day), 'EEE'),
    value: d[dataKey],
  }))

  const values = data.map((d) => d[dataKey])
  const latest = values[values.length - 1] || 0
  const maxValue = Math.max(...values, target || 0)
  const minValue = Math.min(...values.filter(v => v > 0))

  return (
    <div>
      {/* Stats row */}
      <div className="flex items-baseline justify-between mb-2">
        <span className="text-2xl font-bold font-mono text-ink">{latest.toFixed(0)}<span className="text-sm text-muted ml-1">{unit}</span></span>
        {target && (
          <span className="text-xs text-muted">/ {target}{unit}</span>
        )}
      </div>
      
      {/* Chart */}
      <ResponsiveContainer width="100%" height={60}>
        <AreaChart data={chartData} margin={{ top: 0, right: 0, left: 0, bottom: 0 }}>
          <defs>
            <linearGradient id={`gradient-${dataKey}`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={color} stopOpacity={0.3} />
              <stop offset="100%" stopColor={color} stopOpacity={0} />
            </linearGradient>
          </defs>
          <XAxis dataKey="date" hide />
          <YAxis hide domain={[0, maxValue * 1.1]} />
          <Area
            type="monotone"
            dataKey="value"
            stroke={color}
            strokeWidth={2}
            fill={`url(#gradient-${dataKey})`}
            dot={false}
          />
        </AreaChart>
      </ResponsiveContainer>
      
      {/* Day labels */}
      <div className="flex justify-between mt-1">
        {chartData.map((d, i) => (
          <span key={i} className="text-[9px] text-muted">{d.date}</span>
        ))}
      </div>
    </div>
  )
}



