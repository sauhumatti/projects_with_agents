import React from 'react';
import { useOrchestrator } from '../context/OrchestratorContext';

const LEVEL_CONFIG = {
  INFO: { color: 'text-blue-400', icon: 'ℹ️' },
  OK: { color: 'text-green-400', icon: '✓' },
  WARN: { color: 'text-yellow-400', icon: '⚠' },
  ERROR: { color: 'text-red-400', icon: '✗' },
  PHASE: { color: 'text-purple-400', icon: '▸' },
  FATAL: { color: 'text-red-500', icon: '☠' },
};

function LogEntry({ log }) {
  const config = LEVEL_CONFIG[log.level] || LEVEL_CONFIG.INFO;

  // Format timestamp
  const time = log.timestamp?.split(' ')[1] || log.timestamp?.substring(11, 19) || '';

  return (
    <div className="flex gap-2 py-1 px-2 hover:bg-gray-800/50 rounded text-xs font-mono">
      <span className="text-gray-600 w-16 flex-shrink-0">{time}</span>
      <span className={`w-4 ${config.color}`}>{config.icon}</span>
      <span className="text-gray-300 break-all">{log.message}</span>
    </div>
  );
}

export default function ActivityLog() {
  const { logs } = useOrchestrator();

  return (
    <div className="h-full flex flex-col">
      {/* Header */}
      <div className="px-4 py-2 border-b border-gray-800 flex items-center justify-between">
        <h3 className="font-semibold text-white text-sm flex items-center gap-2">
          <svg className="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
          </svg>
          Activity
        </h3>
        <span className="text-xs text-gray-500">
          {logs.length} events
        </span>
      </div>

      {/* Log entries */}
      <div className="flex-1 overflow-auto">
        {logs.length === 0 ? (
          <div className="flex items-center justify-center h-full text-gray-500 text-sm">
            No activity yet
          </div>
        ) : (
          <div className="py-1">
            {logs.map((log, index) => (
              <LogEntry key={`${log.timestamp}-${index}`} log={log} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
