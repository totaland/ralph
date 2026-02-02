import { useCallback, useState, useRef } from 'react';
import type { Node, Edge, NodeChange, EdgeChange, Connection } from '@xyflow/react';
import {
  ReactFlow,
  useNodesState,
  useEdgesState,
  Controls,
  Background,
  BackgroundVariant,
  MarkerType,
  applyNodeChanges,
  applyEdgeChanges,
  addEdge,
  Handle,
  Position,
  reconnectEdge,
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import './App.css';

const nodeWidth = 240;
const nodeHeight = 70;

type Phase = 'setup' | 'loop' | 'decision' | 'done' | 'retry' | 'validate';

const phaseColors: Record<Phase, { bg: string; border: string }> = {
  setup: { bg: '#f0f7ff', border: '#4a90d9' },
  loop: { bg: '#f5f5f5', border: '#666666' },
  decision: { bg: '#fff8e6', border: '#c9a227' },
  done: { bg: '#f0fff4', border: '#38a169' },
  retry: { bg: '#fff0f0', border: '#e53e3e' },
  validate: { bg: '#f0f0ff', border: '#805ad5' },
};

const allSteps: { id: string; label: string; description: string; phase: Phase }[] = [
  // Setup phase (vertical)
  { id: '1', label: 'Write Goal in tasks.md', description: 'Define what you want to build', phase: 'setup' },
  { id: '2', label: 'Run ./ralph.sh plan', description: 'Oracle breaks into tasks', phase: 'setup' },
  { id: '3', label: 'Run ./ralph.sh validate', description: 'Check task structure', phase: 'validate' },
  { id: '4', label: 'Run ./ralph.sh', description: 'Starts the worker loop', phase: 'setup' },
  // Loop phase
  { id: '5', label: 'Find Ready Task', description: 'Check dependencies satisfied', phase: 'loop' },
  { id: '6', label: 'Implement Task', description: 'Worker writes code, runs tests', phase: 'loop' },
  { id: '7', label: 'Tests Pass?', description: '', phase: 'decision' },
  // Retry branch
  { id: '8', label: 'Retry with Backoff', description: 'Exponential delay', phase: 'retry' },
  { id: '9', label: 'Max Retries?', description: '', phase: 'decision' },
  // Success path continues
  { id: '10', label: 'Commit Changes', description: 'If tests pass', phase: 'loop' },
  { id: '11', label: 'Update tasks.md', description: 'Mark task [x] complete', phase: 'loop' },
  { id: '12', label: 'Log to History', description: 'Save to .ralph/history/', phase: 'loop' },
  { id: '13', label: 'More Tasks?', description: '', phase: 'decision' },
  // Exit states
  { id: '14', label: 'Done!', description: 'All tasks complete', phase: 'done' },
  { id: '15', label: 'Exit with Error', description: 'Retries exhausted', phase: 'retry' },
  { id: '16', label: 'Blocked!', description: 'Dependencies unsatisfied', phase: 'retry' },
];

const notes = [
  {
    id: 'note-1',
    appearsWithStep: 3,
    position: { x: 340, y: 180 },
    color: { bg: '#f5f0ff', border: '#8b5cf6' },
    content: `./ralph.sh validate checks:
- Task format (T001, T002...)
- Required fields present
- Dependency references valid
- No circular dependencies`,
  },
  {
    id: 'note-2',
    appearsWithStep: 5,
    position: { x: 340, y: 420 },
    color: { bg: '#e6f3ff', border: '#4a90d9' },
    content: `Dependency check:
- Depends: T001, T002
- Only runs if T001 & T002
  are marked [x] complete`,
  },
  {
    id: 'note-3',
    appearsWithStep: 8,
    position: { x: 680, y: 320 },
    color: { bg: '#fff0f0', border: '#e53e3e' },
    content: `Retry with exponential backoff:
1st: 30s, 2nd: 60s, 3rd: 120s
Configure via:
  RALPH_MAX_RETRIES=2
  RALPH_RETRY_DELAY=30`,
  },
  {
    id: 'note-4',
    appearsWithStep: 12,
    position: { x: 480, y: 680 },
    color: { bg: '#fdf4f0', border: '#c97a50' },
    content: `Logs to .ralph/history/
YYYY-MM-DD.jsonl with:
- timestamp, task, duration
- exit_code, git_head`,
  },
];

function CustomNode({ data }: { data: { title: string; description: string; phase: Phase } }) {
  const colors = phaseColors[data.phase];
  return (
    <div 
      className="custom-node"
      style={{ 
        backgroundColor: colors.bg, 
        borderColor: colors.border 
      }}
    >
      <Handle type="target" position={Position.Top} id="top" />
      <Handle type="target" position={Position.Left} id="left" />
      <Handle type="source" position={Position.Right} id="right" />
      <Handle type="source" position={Position.Bottom} id="bottom" />
      <Handle type="target" position={Position.Right} id="right-target" style={{ right: 0 }} />
      <Handle type="target" position={Position.Bottom} id="bottom-target" style={{ bottom: 0 }} />
      <Handle type="source" position={Position.Top} id="top-source" />
      <Handle type="source" position={Position.Left} id="left-source" />
      <div className="node-content">
        <div className="node-title">{data.title}</div>
        {data.description && <div className="node-description">{data.description}</div>}
      </div>
    </div>
  );
}

function NoteNode({ data }: { data: { content: string; color: { bg: string; border: string } } }) {
  return (
    <div 
      className="note-node"
      style={{
        backgroundColor: data.color.bg,
        borderColor: data.color.border,
      }}
    >
      <pre>{data.content}</pre>
    </div>
  );
}

const nodeTypes = { custom: CustomNode, note: NoteNode };

const positions: { [key: string]: { x: number; y: number } } = {
  // Vertical setup flow on the left
  '1': { x: 20, y: 20 },
  '2': { x: 40, y: 120 },
  '3': { x: 60, y: 220 },
  '4': { x: 40, y: 320 },
  // Loop - find task and implement
  '5': { x: 40, y: 450 },
  '6': { x: 340, y: 450 },
  '7': { x: 600, y: 450 },
  // Retry branch (right side)
  '8': { x: 750, y: 320 },
  '9': { x: 900, y: 450 },
  // Success path continues
  '10': { x: 600, y: 580 },
  '11': { x: 340, y: 580 },
  '12': { x: 180, y: 700 },
  '13': { x: 40, y: 800 },
  // Exit states
  '14': { x: 300, y: 920 },
  '15': { x: 900, y: 580 },
  '16': { x: -180, y: 550 },
  // Notes
  ...Object.fromEntries(notes.map(n => [n.id, n.position])),
};

const edgeConnections: { source: string; target: string; sourceHandle?: string; targetHandle?: string; label?: string }[] = [
  // Setup phase (vertical) - bottom to top connections
  { source: '1', target: '2', sourceHandle: 'bottom', targetHandle: 'top' },
  { source: '2', target: '3', sourceHandle: 'bottom', targetHandle: 'top' },
  { source: '3', target: '4', sourceHandle: 'bottom', targetHandle: 'top' },
  { source: '4', target: '5', sourceHandle: 'bottom', targetHandle: 'top' },
  // Loop phase - find task to implement
  { source: '5', target: '6', sourceHandle: 'right', targetHandle: 'left', label: 'Ready' },
  { source: '5', target: '16', sourceHandle: 'left-source', targetHandle: 'right-target', label: 'Blocked' },
  { source: '6', target: '7', sourceHandle: 'right', targetHandle: 'left' },
  // Decision: Tests Pass?
  { source: '7', target: '8', sourceHandle: 'top-source', targetHandle: 'bottom-target', label: 'No' },
  { source: '7', target: '10', sourceHandle: 'bottom', targetHandle: 'top', label: 'Yes' },
  // Retry loop
  { source: '8', target: '9', sourceHandle: 'right', targetHandle: 'top' },
  { source: '9', target: '6', sourceHandle: 'left-source', targetHandle: 'right-target', label: 'Retry' },
  { source: '9', target: '15', sourceHandle: 'bottom', targetHandle: 'top', label: 'Exhausted' },
  // Success path: commit, update, log
  { source: '10', target: '11', sourceHandle: 'left-source', targetHandle: 'right-target' },
  { source: '11', target: '12', sourceHandle: 'bottom', targetHandle: 'top' },
  { source: '12', target: '13', sourceHandle: 'left-source', targetHandle: 'right-target' },
  // Decision: More tasks?
  { source: '13', target: '5', sourceHandle: 'top-source', targetHandle: 'bottom-target', label: 'Yes' },
  { source: '13', target: '14', sourceHandle: 'bottom', targetHandle: 'top', label: 'No' },
];

function createNode(step: typeof allSteps[0], visible: boolean, position?: { x: number; y: number }): Node {
  return {
    id: step.id,
    type: 'custom',
    position: position || positions[step.id],
    data: {
      title: step.label,
      description: step.description,
      phase: step.phase,
    },
    style: {
      width: nodeWidth,
      height: nodeHeight,
      opacity: visible ? 1 : 0,
      transition: 'opacity 0.5s ease-in-out',
      pointerEvents: visible ? 'auto' : 'none',
    },
  };
}

function createEdge(conn: typeof edgeConnections[0], visible: boolean): Edge {
  return {
    id: `e${conn.source}-${conn.target}`,
    source: conn.source,
    target: conn.target,
    sourceHandle: conn.sourceHandle,
    targetHandle: conn.targetHandle,
    label: visible ? conn.label : undefined,
    animated: visible,
    style: {
      stroke: '#222',
      strokeWidth: 2,
      opacity: visible ? 1 : 0,
      transition: 'opacity 0.5s ease-in-out',
    },
    labelStyle: {
      fill: '#222',
      fontWeight: 600,
      fontSize: 14,
    },
    labelShowBg: true,
    labelBgPadding: [8, 4] as [number, number],
    labelBgStyle: {
      fill: '#fff',
      stroke: '#222',
      strokeWidth: 1,
    },
    markerEnd: {
      type: MarkerType.ArrowClosed,
      color: '#222',
    },
  };
}

function createNoteNode(note: typeof notes[0], visible: boolean, position?: { x: number; y: number }): Node {
  return {
    id: note.id,
    type: 'note',
    position: position || positions[note.id],
    data: { content: note.content, color: note.color },
    style: {
      opacity: visible ? 1 : 0,
      transition: 'opacity 0.5s ease-in-out',
      pointerEvents: visible ? 'auto' : 'none',
    },
    draggable: true,
    selectable: false,
    connectable: false,
  };
}

function App() {
  const [visibleCount, setVisibleCount] = useState(1);
  const nodePositions = useRef<{ [key: string]: { x: number; y: number } }>({ ...positions });

  const getNodes = (count: number) => {
    const stepNodes = allSteps.map((step, index) =>
      createNode(step, index < count, nodePositions.current[step.id])
    );
    const noteNodes = notes.map(note => {
      const noteVisible = count >= note.appearsWithStep;
      return createNoteNode(note, noteVisible, nodePositions.current[note.id]);
    });
    return [...stepNodes, ...noteNodes];
  };

  const initialNodes = getNodes(1);
  const initialEdges = edgeConnections.map((conn, index) =>
    createEdge(conn, index < 0)
  );

  const [nodes, setNodes] = useNodesState(initialNodes);
  const [edges, setEdges] = useEdgesState(initialEdges);

  const onNodesChange = useCallback(
    (changes: NodeChange[]) => {
      changes.forEach((change) => {
        if (change.type === 'position' && change.position) {
          nodePositions.current[change.id] = change.position;
        }
      });
      setNodes((nds) => applyNodeChanges(changes, nds));
    },
    [setNodes]
  );

  const onEdgesChange = useCallback(
    (changes: EdgeChange[]) => {
      setEdges((eds) => applyEdgeChanges(changes, eds));
    },
    [setEdges]
  );

  const onConnect = useCallback(
    (connection: Connection) => {
      setEdges((eds) => addEdge({ ...connection, animated: true, style: { stroke: '#222', strokeWidth: 2 }, markerEnd: { type: MarkerType.ArrowClosed, color: '#222' } }, eds));
    },
    [setEdges]
  );

  const onReconnect = useCallback(
    (oldEdge: Edge, newConnection: Connection) => {
      setEdges((eds) => reconnectEdge(oldEdge, newConnection, eds));
    },
    [setEdges]
  );

  const getEdgeVisibility = (conn: typeof edgeConnections[0], visibleStepCount: number) => {
    const sourceIndex = allSteps.findIndex(s => s.id === conn.source);
    const targetIndex = allSteps.findIndex(s => s.id === conn.target);
    return sourceIndex < visibleStepCount && targetIndex < visibleStepCount;
  };

  const handleNext = useCallback(() => {
    if (visibleCount < allSteps.length) {
      const newCount = visibleCount + 1;
      setVisibleCount(newCount);

      setNodes(getNodes(newCount));
      setEdges(
        edgeConnections.map((conn) =>
          createEdge(conn, getEdgeVisibility(conn, newCount))
        )
      );
    }
  }, [visibleCount, setNodes, setEdges]);

  const handlePrev = useCallback(() => {
    if (visibleCount > 1) {
      const newCount = visibleCount - 1;
      setVisibleCount(newCount);

      setNodes(getNodes(newCount));
      setEdges(
        edgeConnections.map((conn) =>
          createEdge(conn, getEdgeVisibility(conn, newCount))
        )
      );
    }
  }, [visibleCount, setNodes, setEdges]);

  const handleReset = useCallback(() => {
    setVisibleCount(1);
    nodePositions.current = { ...positions };
    setNodes(getNodes(1));
    setEdges(edgeConnections.map((conn, index) => createEdge(conn, index < 0)));
  }, [setNodes, setEdges]);

  return (
    <div className="app-container">
      <div className="header">
        <h1>How Ralph v2 Works with Amp</h1>
        <p>Autonomous AI agent loop with task dependencies and retry logic</p>
      </div>
      <div className="flow-container">
        <ReactFlow
          nodes={nodes}
          edges={edges}
          nodeTypes={nodeTypes}
          onNodesChange={onNodesChange}
          onEdgesChange={onEdgesChange}
          onConnect={onConnect}
          onReconnect={onReconnect}
          fitView
          fitViewOptions={{ padding: 0.2 }}
          nodesDraggable={true}
          nodesConnectable={true}
          edgesReconnectable={true}
          elementsSelectable={true}
          deleteKeyCode={['Backspace', 'Delete']}
          panOnDrag={true}
          panOnScroll={true}
          zoomOnScroll={true}
          zoomOnPinch={true}
          zoomOnDoubleClick={true}
          selectNodesOnDrag={false}
        >
          <Background variant={BackgroundVariant.Dots} gap={20} size={1} color="#ddd" />
          <Controls showInteractive={false} />
        </ReactFlow>
      </div>
      <div className="controls">
        <button onClick={handlePrev} disabled={visibleCount <= 1}>
          Previous
        </button>
        <span className="step-counter">
          Step {visibleCount} of {allSteps.length}
        </span>
        <button onClick={handleNext} disabled={visibleCount >= allSteps.length}>
          Next
        </button>
        <button onClick={handleReset} className="reset-btn">
          Reset
        </button>
      </div>
      <div className="instructions">
        Click Next to reveal each step — includes validate, dependencies, and retry flow
      </div>
    </div>
  );
}

export default App;
