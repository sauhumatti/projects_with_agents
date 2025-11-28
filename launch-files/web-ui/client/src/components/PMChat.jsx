import React, { useState, useRef, useEffect } from 'react';
import { useOrchestrator } from '../context/OrchestratorContext';

function MessageBubble({ message, onRespond }) {
  const [response, setResponse] = useState('');
  const [isResponding, setIsResponding] = useState(false);
  const [expanded, setExpanded] = useState(true);

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!response.trim()) return;

    setIsResponding(true);
    const success = await onRespond(message.id, response);
    if (success) {
      setResponse('');
    }
    setIsResponding(false);
  };

  const priorityColors = {
    blocking: 'border-red-500 bg-red-900/20',
    high: 'border-orange-500 bg-orange-900/20',
    normal: 'border-blue-500 bg-blue-900/20',
    low: 'border-gray-500 bg-gray-900/20',
  };

  const priorityConfig = priorityColors[message.priority] || priorityColors.normal;

  return (
    <div className={`rounded-lg border ${priorityConfig} p-3 mb-3 animate-slide-in`}>
      {/* Header */}
      <div className="flex items-center justify-between mb-2">
        <div className="flex items-center gap-2">
          <span className="text-xs font-medium text-blue-400">PM</span>
          {message.priority === 'blocking' && (
            <span className="px-1.5 py-0.5 text-xs bg-red-600 text-white rounded animate-pulse">
              BLOCKING
            </span>
          )}
          {message.from && (
            <span className="text-xs text-gray-500">
              from {message.from}
            </span>
          )}
        </div>
        <button
          onClick={() => setExpanded(!expanded)}
          className="text-gray-400 hover:text-white"
        >
          <svg className={`w-4 h-4 transition-transform ${expanded ? 'rotate-180' : ''}`} fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>
      </div>

      {expanded && (
        <>
          {/* Task context */}
          {message.task && (
            <div className="text-xs text-gray-500 mb-2">
              Task: {message.task}
            </div>
          )}

          {/* Question */}
          <div className="text-sm text-white mb-3 whitespace-pre-wrap">
            {message.question || message.message}
          </div>

          {/* Response form */}
          {!message.hasResponse && (
            <form onSubmit={handleSubmit} className="space-y-2">
              <textarea
                value={response}
                onChange={(e) => setResponse(e.target.value)}
                placeholder="Type your response..."
                className="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-sm text-white placeholder-gray-500 focus:outline-none focus:border-blue-500 resize-none"
                rows={3}
                disabled={isResponding}
              />
              <div className="flex justify-end">
                <button
                  type="submit"
                  disabled={isResponding || !response.trim()}
                  className="px-4 py-1.5 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-700 disabled:text-gray-500 text-white text-sm rounded transition-colors flex items-center gap-2"
                >
                  {isResponding ? (
                    <>
                      <svg className="animate-spin h-4 w-4" fill="none" viewBox="0 0 24 24">
                        <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                        <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
                      </svg>
                      Sending...
                    </>
                  ) : (
                    'Send Response'
                  )}
                </button>
              </div>
            </form>
          )}

          {message.hasResponse && (
            <div className="text-xs text-green-400 flex items-center gap-1">
              <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
              </svg>
              Responded
            </div>
          )}
        </>
      )}
    </div>
  );
}

export default function PMChat() {
  const { messages, respondToMessage } = useOrchestrator();
  const scrollRef = useRef(null);

  // Auto-scroll when new messages arrive
  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = 0;
    }
  }, [messages.length]);

  const pendingMessages = messages.filter(m => !m.hasResponse);
  const respondedMessages = messages.filter(m => m.hasResponse);

  return (
    <div className="h-full flex flex-col">
      {/* Header */}
      <div className="px-4 py-2 border-b border-gray-800 flex items-center justify-between">
        <h3 className="font-semibold text-white text-sm flex items-center gap-2">
          <svg className="w-4 h-4 text-purple-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z" />
          </svg>
          PM Chat
        </h3>
        {pendingMessages.length > 0 && (
          <span className="px-2 py-0.5 bg-red-600 text-white text-xs rounded-full animate-pulse">
            {pendingMessages.length}
          </span>
        )}
      </div>

      {/* Messages */}
      <div ref={scrollRef} className="flex-1 overflow-auto p-3">
        {messages.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full text-center">
            <svg className="w-12 h-12 text-gray-700 mb-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1} d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z" />
            </svg>
            <p className="text-gray-500 text-sm">No messages yet</p>
            <p className="text-gray-600 text-xs mt-1">
              PM questions will appear here
            </p>
          </div>
        ) : (
          <>
            {/* Pending messages first */}
            {pendingMessages.map(message => (
              <MessageBubble
                key={message.id}
                message={message}
                onRespond={respondToMessage}
              />
            ))}

            {/* Separator if both types exist */}
            {pendingMessages.length > 0 && respondedMessages.length > 0 && (
              <div className="flex items-center gap-2 my-4 text-xs text-gray-600">
                <div className="flex-1 h-px bg-gray-800" />
                <span>Responded</span>
                <div className="flex-1 h-px bg-gray-800" />
              </div>
            )}

            {/* Responded messages */}
            {respondedMessages.map(message => (
              <MessageBubble
                key={message.id}
                message={message}
                onRespond={respondToMessage}
              />
            ))}
          </>
        )}
      </div>
    </div>
  );
}
