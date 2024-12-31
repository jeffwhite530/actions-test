#!/usr/bin/env python3

# pylint: disable=bad-indentation, line-too-long, logging-fstring-interpolation

import subprocess
import time
import os
import logging
import sys
from typing import Dict, Optional, Tuple
import kubernetes.client
import kubernetes.config
import kubernetes.watch


def setup_logging() -> None:
  """Configure logging with timestamp and log level."""
  root = logging.getLogger()
  if root.handlers:
    for handler in root.handlers:
      root.removeHandler(handler)

  logging.basicConfig(
    format='%(asctime)s - %(levelname)s - %(message)s',
    level=logging.INFO,
    stream=sys.stdout
  )


def get_slurm_nodes() -> Dict[str, Dict[str, str]]:
  """Get current list of nodes in Slurm with their properties.
  
  Returns:
    Dict mapping node names to their properties dict containing state and nodeaddr
  """
  try:
    result = subprocess.run(
      ['scontrol', 'show', 'nodes', '-o'],
      capture_output=True,
      text=True,
      check=True
    )
    nodes = {}
    for line in result.stdout.splitlines():
      if line.strip():
        properties = {}
        for item in line.split():
          if '=' in item:
            key, value = item.split('=', 1)
            properties[key.lower()] = value
        if 'nodename' in properties:
          nodes[properties['nodename']] = properties
    return nodes
  except subprocess.CalledProcessError as error:
    logging.error(f"Failed to get Slurm nodes: {error}")
    return {}


def check_node_exists(node_name: str) -> Tuple[bool, Optional[Dict[str, str]]]:
  """Check if a node exists in Slurm and return its properties if it does.
  
  Args:
    node_name: Name of the node to check
    
  Returns:
    Tuple of (exists: bool, properties: Optional[Dict[str, str]])
  """
  try:
    result = subprocess.run(
      ['scontrol', 'show', 'node', node_name, '-o'],
      capture_output=True,
      text=True,
      check=False
    )
    if result.returncode == 0 and result.stdout.strip():
      properties = {}
      for item in result.stdout.split():
        if '=' in item:
          key, value = item.split('=', 1)
          properties[key.lower()] = value
      return True, properties
    return False, None
  except subprocess.CalledProcessError as error:
    logging.error(f"Error checking node existence for {node_name}: {error}")
    return False, None


def add_slurm_node(pod_name: str) -> None:
  """Add a new node to Slurm if it doesn't already exist.
  
  Args:
    pod_name: Name of the pod to add as a Slurm node
  """
  exists, properties = check_node_exists(pod_name)
  if exists:
    # Node already exists, let slurmd handle its registration
    logging.info(f"Node {pod_name} already exists in Slurm")
    return

  try:
    subprocess.run([
      'scontrol', 'create', 'nodename=' + pod_name,
      'state=CLOUD'
    ], check=True)
    logging.info(f"Added node {pod_name} to Slurm")
  except subprocess.CalledProcessError as error:
    logging.error(f"Failed to add node {pod_name}: {error}")


def remove_slurm_node(node_name: str) -> None:
  """Remove a node from Slurm if it exists.
  
  Args:
    node_name: Name of the node to remove from Slurm
  """
  exists, _ = check_node_exists(node_name)
  if not exists:
    logging.info(f"Node {node_name} doesn't exist in Slurm, skipping removal")
    return

  try:
    # Just delete the node - pod is already gone
    subprocess.run(['scontrol', 'delete', f'nodename={node_name}'], check=True)
    logging.info(f"Removed node {node_name}")
  except subprocess.CalledProcessError as error:
    logging.error(f"Failed to remove node {node_name}: {error}")


def is_pod_ready(pod: kubernetes.client.V1Pod) -> bool:
  """Check if a pod is in Ready state.
  
  Args:
    pod: The pod to check
    
  Returns:
    bool: True if pod is running and ready, False otherwise
  """
  if pod.status.phase != 'Running':
    logging.info(f"Pod {pod.metadata.name} not ready: phase is {pod.status.phase}")
    return False

  if not pod.status.conditions:
    logging.info(f"Pod {pod.metadata.name} not ready: no conditions")
    return False

  for condition in pod.status.conditions:
    if condition.type == 'Ready':
      if condition.status != 'True':
        logging.info(f"Pod {pod.metadata.name} not ready: Ready condition is {condition.status} ({condition.message})")
      return condition.status == 'True'

  logging.info(f"Pod {pod.metadata.name} not ready: no Ready condition found")
  return False


def sync_slurm_nodes(core_api: kubernetes.client.CoreV1Api, namespace: str, 
                     label_selector: str) -> None:
  """Perform initial sync between Kubernetes pods and Slurm nodes.
  
  Args:
    core_api: Kubernetes API client
    namespace: Namespace to watch
    label_selector: Label selector for slurmd pods
  """
  logging.info("Performing initial sync...")
  pods = core_api.list_namespaced_pod(namespace, label_selector=label_selector)
  current_pods = {pod.metadata.name: pod for pod in pods.items}

  slurm_nodes = get_slurm_nodes()

  # Add missing nodes
  for pod_name, pod in current_pods.items():
    if ((pod_name not in slurm_nodes or 
         slurm_nodes[pod_name].get('state') == 'DOWN') and 
        is_pod_ready(pod)):
      add_slurm_node(pod_name)

  # Remove extra nodes
  for node_name in slurm_nodes:
    if node_name not in current_pods:
      remove_slurm_node(node_name)

  logging.info("Initial sync complete")


def watch_pod_events(core_api: kubernetes.client.CoreV1Api, namespace: str,
                    label_selector: str) -> None:
  """Watch for pod events and update Slurm nodes accordingly.
  
  Args:
    core_api: Kubernetes API client
    namespace: Namespace to watch
    label_selector: Label selector for slurmd pods
  """
  logging.info("Starting to watch for pod events...")
  watcher = kubernetes.watch.Watch()

  while True:
    try:
      for event in watcher.stream(
        core_api.list_namespaced_pod,
        namespace,
        label_selector=label_selector
      ):
        pod = event['object']
        pod_name = pod.metadata.name

        # Log detailed pod state for all events
        logging.info(f"Event {event['type']} for pod {pod_name}:")
        logging.info(f"  Phase: {pod.status.phase}")
        if pod.status.conditions:
          for condition in pod.status.conditions:
            logging.info(f"  Condition {condition.type}: {condition.status} ({condition.message if hasattr(condition, 'message') else 'no message'})")
        else:
          logging.info("  No conditions")

        if event['type'] == 'DELETED':
          remove_slurm_node(pod_name)
          continue

        # Skip if pod isn't ready for non-delete events
        if not is_pod_ready(pod):
          logging.info(f"Skipping {event['type']} event for pod {pod_name} - not ready")
          continue

        if event['type'] == 'ADDED':
          add_slurm_node(pod_name)
          continue

        if event['type'] == 'MODIFIED':
          exists, properties = check_node_exists(pod_name)
          if not exists:
            # If node doesn't exist and pod is ready, add it (just like ADDED)
            add_slurm_node(pod_name)
            continue

          # If node exists but is down, try re-adding it
          state = properties.get('state', '').upper()
          if 'DOWN' in state:
            logging.info(f"Node {pod_name} found in {state} state, attempting to re-add")
            remove_slurm_node(pod_name)
            add_slurm_node(pod_name)

    except Exception as error:
      logging.error(f"Error in watch loop: {error}")
      time.sleep(5)  # Wait before retrying


def main() -> None:
  """Main controller loop."""
  setup_logging()
  logging.info("Starting Slurm node controller")

  # Load kube config
  if os.path.exists('/var/run/secrets/kubernetes.io/serviceaccount'):
    kubernetes.config.load_incluster_config()
  else:
    kubernetes.config.load_kube_config()

  core_api = kubernetes.client.CoreV1Api()
  namespace = os.getenv('NAMESPACE', 'default')
  label_selector = 'app.kubernetes.io/component=slurmd'

  # Perform initial sync
  sync_slurm_nodes(core_api, namespace, label_selector)

  # Watch for changes
  watch_pod_events(core_api, namespace, label_selector)


if __name__ == '__main__':
  main()
