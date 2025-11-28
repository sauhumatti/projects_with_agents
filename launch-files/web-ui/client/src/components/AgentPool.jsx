import React from 'react';
import { useOrchestrator } from '../context/OrchestratorContext';

const STATUS_COLORS = {
  active: { bg: 'bg-green-500', text: 'text-green-400', label: 'Active' },
  running: { bg: 'bg-yellow-500', text: 'text-yellow-400', label: 'Running' },
  standby: { bg: 'bg-blue-500', text: 'text-blue-400', label: 'Standby' },
  starting: { bg: 'bg-purple-500', text: 'text-purple-400', label: 'Starting' },
  completed: { bg: 'bg-gray-500', text: 'text-gray-400', label: 'Completed' },
  terminated: { bg: 'bg-red-500', text: 'text-red-400', label: 'Terminated' },
  assigned: { bg: 'bg-orange-500', text: 'text-orange-400', label: 'Assigned' },
};

function AgentCard({ id, agent }) {
  const status = agent.status || 'unknown';
  const statusConfig = STATUS_COLORS[status] || { bg: 'bg-gray-500', text: 'text-gray-400', label: status };

  return (
    <div className="flex items-center gap-3 p-2 hover:bg-gray-800 rounded transition-colors">
      {/* Status indicator */}
      <span className={`w-2 h-2 rounded-full ${statusConfig.bg} ${status === 'active' || status === 'running' ? 'animate-pulse' : ''}`} />

      {/* Agent info */}
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-sm text-white truncate">{id}</span>
          <span className={`text-xs ${statusConfig.text}`}>
            {statusConfig.label}
          </span>
        </div>
        {agent.currentTask && (
          <div className="text-xs text-gray-500 truncate">
            Task: {agent.currentTask}
          </div>
        )}
      </div>

      {/* Agent type badge */}
      <span className="px-2 py-0.5 text-xs rounded bg-gray-700 text-gray-300">
        {agent.type || agent.role || 'agent'}
      </span>
    </div>
  );
}

export default function AgentPool() {
  const { pool, agents } = useOrchestrator();

  // Merge pool and agents data
  const allAgents = { ...pool };
  for (const [id, data] of Object.entries(agents)) {
    if (!allAgents[id]) {
      allAgents[id] = data;
    } else {
      allAgents[id] = { ...allAgents[id], ...data };
    }
  }

  const agentList = Object.entries(allAgents);
  const activeCount = agentList.filter(([, a]) => a.status === 'active' || a.status === 'running').length;
  const standbyCount = agentList.filter(([, a]) => a.status === 'standby').length;

  return (
    <div className="h-full flex flex-col">
      {/* Header */}
      <div className="px-4 py-2 border-b border-gray-800 flex items-center justify-between">
        <h3 className="font-semibold text-white text-sm flex items-center gap-2">
          <svg className="w-4 h-4 text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z" />
          </svg>
          Agent Pool
        </h3>
        <div className="flex items-center gap-2 text-xs">
          {activeCount > 0 && (
            <span className="px-1.5 py-0.5 bg-green-900/50 text-green-400 rounded">
              {activeCount} active
            </span>
          )}
          {standbyCount > 0 && (
            <span className="px-1.5 py-0.5 bg-blue-900/50 text-blue-400 rounded">
              {standbyCount} standby
            </span>
          )}
        </div>
      </div>

      {/* Agent list */}
      <div className="flex-1 overflow-auto p-2">
        {agentList.length === 0 ? (
          <div className="text-center py-4 text-gray-500 text-sm">
            No agents in pool
          </div>
        ) : (
          agentList.map(([id, agent]) => (
            <AgentCard key={id} id={id} agent={agent} />
          ))
        )}
      </div>
    </div>
  );
}
